defmodule ImagePipe.Plug.DialectRunner do
  @moduledoc false
  # The unified dialect lifecycle (design 2026-07-19, decisions U1–U5).
  # This module branches ONLY on %Resolved{} fields and neutral core structs
  # (U4) — it must never name a dialect or accept a dialect-specific option.

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Dialect.DebugContext
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Plug.DebugBuilder
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  @spec run(Plug.Conn.t(), module(), keyword()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, dialect, config) do
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, config)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, dialect, config)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  # -- route: OPTIONS/405 guards, then parse → prepare → resolve → serve ------

  defp route(%Plug.Conn{method: "OPTIONS"} = conn, _dialect, config) do
    conn = send_with_span(conn, config, :options, fn -> CORS.send_options(conn, config) end)
    {conn, %{result: :options}}
  end

  defp route(%Plug.Conn{method: method} = conn, _dialect, config)
       when method not in ["GET", "HEAD"] do
    conn =
      send_with_span(conn, config, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp route(%Plug.Conn{} = conn, dialect, config) do
    case parse(conn, dialect, config) do
      {:ok, request} ->
        handle_request(conn, dialect, request, config)

      {:redirect, status, location} ->
        conn =
          send_with_span(conn, config, :redirect, fn ->
            Sender.send_redirect(conn, status, location)
          end)

        {conn, %{result: :redirect, status: status}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end

  # `Telemetry.span/4`'s callback must return `{result, stop_metadata}` —
  # `dialect.parse/2` already returns exactly that tuple, passed through
  # unwrapped.
  defp parse(%Plug.Conn{} = conn, dialect, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      dialect.parse(conn, config)
    end)
  end

  defp handle_request(conn, dialect, request, config) do
    with {:ok, %Resolved{} = resolved} <- dialect.prepare(conn, request, config),
         {:ok, %ImageSource.Resolved{} = source} <-
           ImageSource.resolve(resolved.source, config, config),
         {:ok, %Negotiation{} = negotiation, material} <- resolved.negotiation do
      representation =
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)

      if Conditional.not_modified?(conn, representation.etag) do
        send_not_modified(conn, representation, config)
      else
        serve_terminal(conn, dialect, resolved, source, negotiation, representation, config)
      end
    else
      {:error, reason} -> send_error(conn, dialect, reason, config)
    end
  end

  # -- terminal dispatch (Resolved-neutral: branches on %Resolved{terminal:}) --

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: :image} = resolved,
         source,
         negotiation,
         representation,
         config
       ),
       do: serve(conn, dialect, resolved, source, negotiation, representation, config)

  # -- render terminal: consolidated from imgproxy /info + Native blurhash.
  # -- Phase A's sole render delivery is the complete-body lifecycle; the
  # -- spec's cache-:none/offers variant arrives with Phase C's widening.

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, terminal}} = resolved,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         _negotiation,
         representation,
         config
       ),
       do: generate_render(conn, dialect, resolved, terminal, source, representation, nil, config)

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, terminal}} = resolved,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         _negotiation,
         representation,
         config
       ) do
    case Cache.lookup_entry(representation.cache_key, config) do
      {:hit, %Cache.Entry{representation: {:complete_body, content_type}} = entry} ->
        deliver_render_hit(conn, content_type, entry.body, representation, config)

      # A miss, a disabled cache, or an untagged entry (indistinguishable from
      # an image entry — sending one here would answer the render terminal
      # with image bytes) all regenerate.
      _miss_or_untagged ->
        generate_render(
          conn,
          dialect,
          resolved,
          terminal,
          source,
          representation,
          representation.cache_key,
          config
        )
    end
  end

  defp deliver_render_hit(conn, content_type, body, representation, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, representation, config)
    else
      conn =
        send_with_span(conn, config, :ok, fn ->
          send_complete_body(conn, content_type, body, representation)
        end)

      {conn, %{result: :ok}}
    end
  end

  defp generate_render(
         conn,
         dialect,
         _resolved,
         terminal,
         source,
         representation,
         cache_key,
         config
       ) do
    started_at = System.monotonic_time(:microsecond)

    case terminal.fun.(source, config) do
      {:ok, content_type, body} ->
        cost_us = System.monotonic_time(:microsecond) - started_at
        write_complete_body_cache(cache_key, content_type, body, cost_us, config)

        conn =
          send_with_span(conn, config, :ok, fn ->
            send_complete_body(conn, content_type, body, representation)
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end

  defp write_complete_body_cache(nil = _cache_disabled, _ct, _body, _cost_us, _config), do: :ok

  defp write_complete_body_cache(%Cache.Key{} = cache_key, content_type, body, cost_us, config) do
    cache_key
    |> Cache.open_sink({:complete_body, content_type}, Keyword.put(config, :cost_us, cost_us))
    |> Cache.write_chunk(IO.iodata_to_binary(body), config)
    |> Cache.commit_sink(config)

    :ok
  end

  defp send_complete_body(conn, content_type, body, %Representation{} = representation) do
    cache_headers = CacheHeaders.from_representation(representation)

    conn
    |> put_resp_headers(cache_headers.representation_headers)
    |> put_resp_headers(cache_headers.headers)
    |> Plug.Conn.put_resp_content_type(content_type, nil)
    |> Plug.Conn.send_resp(200, body)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
  end

  # -- serve: cache dispatch (Resolved-neutral: branches on Source.Resolved) --

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         negotiation,
         representation,
         config
       ) do
    generate(conn, dialect, resolved, source, negotiation, representation, nil, config)
  end

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         negotiation,
         representation,
         config
       ) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, dialect, resolved, entry, representation, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          dialect,
          resolved,
          source,
          negotiation,
          representation,
          representation.cache_key,
          config
        )
    end
  end

  # A cache hit is the proof that a current representation exists for this
  # key — the only place `If-None-Match: *` may be honored (mirrors every
  # dialect chain and Request.Runner).
  defp deliver_hit(conn, dialect, resolved, entry, representation, cache_serve_us, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, representation, config)
    else
      deliver_hit_entry(conn, dialect, resolved, entry, representation, cache_serve_us, config)
    end
  end

  # A warmed `{:complete_body, content_type}` entry must NOT flow through
  # `Sender`'s image-entry delivery, which assumes an encoder output
  # (`Plan.Response.content_disposition/2` only knows the fixed image
  # delivery content types and errors on anything else).
  defp deliver_hit_entry(
         conn,
         _dialect,
         _resolved,
         %Cache.Entry{representation: {:complete_body, content_type}} = entry,
         representation,
         _cache_serve_us,
         config
       ) do
    conn =
      send_with_span(conn, config, :ok, fn ->
        send_complete_body(conn, content_type, entry.body, representation)
      end)

    {conn, %{result: :ok}}
  end

  defp deliver_hit_entry(conn, _dialect, resolved, entry, representation, cache_serve_us, config) do
    hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}

    conn =
      send_with_span(conn, config, :ok, fn ->
        Sender.send_result(
          conn,
          {:ok,
           {:cache_entry, entry, resolved.response_meta,
            CacheHeaders.from_representation(representation), hit_debug}},
          delivery_config(resolved, config)
        )
      end)

    {conn, %{result: :ok}}
  end

  # -- image terminal: Delivery.stream over produce_stream ---------------------

  defp generate(
         conn,
         dialect,
         %Resolved{terminal: :image} = resolved,
         source,
         negotiation,
         representation,
         cache_key,
         config
       ) do
    build_fun = build_fun(dialect, resolved, source, negotiation, config)

    case Delivery.stream(self(), build_fun, cache_key, resolved.response_meta, config) do
      {:ok, prepared} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:prepared_stream, prepared, resolved.response_meta,
                CacheHeaders.from_representation(representation)}},
              delivery_config(resolved, config)
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        # Phase B note: imgproxy/TwicPics ride negotiation.policy.headers on
        # delivery errors (their Errors.send/4); Native's Errors.send/3 takes
        # none, so Phase A's contract carries no headers here — see the plan's
        # exit notes for the Phase B design question.
        send_error(conn, dialect, reason, config)
    end
  end

  defp build_fun(dialect, %Resolved{} = resolved, source, negotiation, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, resolved.auto_rotate?)
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      decode_started_at = System.monotonic_time(:microsecond)

      Decode.with_image(
        source,
        decode_opts,
        &dialect.decode_request(resolved.request, &1),
        fn state, geometry ->
          decode_us = System.monotonic_time(:microsecond) - decode_started_at

          try do
            produce_stream(
              dialect,
              state,
              geometry,
              resolved,
              negotiation,
              config,
              pump,
              decode_us
            )
          after
            on_bracket_exit.()
          end
        end
      )
    end
  end

  # transform → resolve output → clamp → materialize → encode first chunk →
  # hand off. Runs inside Delivery.Producer. (The dialects' build_and_pump,
  # written once — spec §The runner.)
  defp produce_stream(dialect, state, geometry, resolved, negotiation, config, pump, decode_us) do
    shrink = state.decode_shrink

    with {{:ok, %State{} = state}, transform_us} <-
           Timing.measure(fn ->
             run_transform(dialect, state, geometry, resolved, negotiation, config)
           end),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image, config),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             config
           ),
         {:ok, %State{image: image}} <-
           materialize_for_delivery(%State{state | image: clamped}, config),
         {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} <-
           Timing.measure(fn -> encode_first_chunk(image, resolved_output, config) end) do
      debug =
        DebugBuilder.build(dialect, %DebugContext{
          geometry: geometry,
          shrink: shrink,
          negotiation: negotiation,
          resolved_output: resolved_output,
          image: image,
          search_meta: search_meta,
          operations: resolved.operations,
          timings: %{decode: decode_us, transform: transform_us, encode: encode_us}
        })

      pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, debug)
    else
      {:empty, _microseconds} -> {:error, {:encode, :empty_stream}}
      {{:error, _reason} = error, _microseconds} -> error
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  defp run_transform(dialect, state, geometry, %Resolved{} = resolved, negotiation, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: resolved.operations, operation_count: length(resolved.operations)},
      fn ->
        result =
          dialect.execute(
            state,
            geometry,
            resolved.request,
            pipeline_opts(negotiation, geometry, config)
          )

        {result, transform_stop_metadata(result)}
      end
    )
  end

  # ex_dna:disable-for-next-line
  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  # `supports_hdr?` from the negotiation's own policy + plan_output — never
  # from the opaque request. Conservative false when there is no policy.
  defp pipeline_opts(%Negotiation{policy: nil}, _geometry, config),
    do: Keyword.put(config, :supports_hdr?, false)

  defp pipeline_opts(%Negotiation{} = negotiation, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(negotiation.policy, negotiation.plan_output, geometry.source_format)
    )
  end

  defp resolve_output(policy, source_format, image, config) do
    Negotiate.negotiate_output(
      policy,
      source_format,
      fn -> Image.has_alpha?(image) end,
      Telemetry.telemetry_opts(config)
    )
  end

  # ex_dna:disable-for-next-line
  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, config),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  defp first_chunk(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  # ex_dna:disable-for-next-line
  defp encode_stop_metadata({:ok, _chunk, _ct, _stream_state, _meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  # ex_dna:disable-for-next-line
  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    case Materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # ex_dna:disable-for-next-line
  defp result_limits(format, config) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
      max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
      max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
    }
  end

  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)

  defp delivery_config(%Resolved{} = resolved, config) do
    Keyword.put(
      config,
      :debug?,
      resolved.debug? and Keyword.get(config, :allow_debug_headers, false)
    )
  end

  # -- terminal sends ---------------------------------------------------------

  # ex_dna:disable-for-next-line
  defp send_with_span(%Plug.Conn{}, config, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:send], %{result: result}, fn ->
      sent_conn = fun.()

      {sent_conn,
       %{
         result: Map.get(sent_conn.private, :image_pipe_send_result, result),
         status: sent_conn.status
       }}
    end)
  end

  # ex_dna:disable-for-next-line
  defp send_not_modified(conn, %Representation{} = representation, config) do
    conn =
      send_with_span(conn, config, :not_modified, fn ->
        Sender.send_result(
          conn,
          {:not_modified, CacheHeaders.from_representation(representation)},
          config
        )
      end)

    {conn, %{result: :not_modified}}
  end

  defp send_error(conn, dialect, reason, config) do
    metadata = %{result: classify(dialect, reason), error: Error.tag(reason)}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        dialect.render_error(conn, reason, config)
      end)

    {conn, metadata}
  end

  defp classify(dialect, reason) do
    if function_exported?(dialect, :classify_error, 1) do
      dialect.classify_error(reason)
    else
      Telemetry.request_result({:error, reason})
    end
  end
end

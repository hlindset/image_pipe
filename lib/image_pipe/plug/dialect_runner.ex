defmodule ImagePipe.Plug.DialectRunner do
  @moduledoc false
  # The unified dialect lifecycle (design 2026-07-19, decisions U1–U5).
  # This module branches ONLY on %Resolved{} fields and neutral core structs
  # (U4) — it must never name a dialect or accept a dialect-specific option.

  require Logger

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Dialect.DebugContext
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.RenderTerminal
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
  alias ImagePipe.Response.CachePolicy
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

      # A committed 200 whose stream then failed: the shared Sender stamps
      # :image_pipe_send_result (:processing_error), and the request span's
      # stop result must agree with the [:send] stop.
      metadata =
        metadata
        |> Map.put(:result, Map.get(conn.private, :image_pipe_send_result, metadata.result))
        |> Map.put(:status, conn.status)

      {conn, metadata}
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
           ImageSource.resolve(resolved.source, config, ImageSource.runtime_opts(config)),
         {:ok, %Negotiation{} = negotiation, material} <-
           resolve_negotiation(resolved.negotiation) do
      representation =
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)

      # The generated-header policy runs HERE — before the conditional gate —
      # because its ETag suppression (mode :disabled, a host Set-Cookie /
      # Vary: * / Cache-Control: no-store, a byte-identity-less source) must
      # be able to veto the 304.
      cache_headers = cache_headers(conn, resolved, representation, source, config)

      if Conditional.not_modified?(conn, cache_headers.etag) do
        maybe_emit_conditional_match(conn, resolved, config)
        send_not_modified(conn, cache_headers, config)
      else
        serve_terminal(
          conn,
          dialect,
          resolved,
          source,
          negotiation,
          representation,
          cache_headers,
          config
        )
      end
    else
      {:error, reason} -> send_error(conn, dialect, reason, config)
    end
  end

  defp cache_headers(
         _conn,
         %Resolved{http_cache: :dialect_owned},
         representation,
         _source,
         _config
       ),
       do: CacheHeaders.from_representation(representation)

  defp cache_headers(conn, %Resolved{http_cache: :generated}, representation, source, config),
    do: CachePolicy.generate(conn, representation, source_facts(source), config)

  defp source_facts(%ImageSource.Resolved{} = source) do
    %{
      http_cache: source.http_cache,
      byte_identity: source.cache_semantics.byte_identity,
      stable?: source.cache_semantics.stable?,
      adapter: source.adapter,
      source_kind: source.source_kind
    }
  end

  defp maybe_emit_conditional_match(conn, %Resolved{http_cache: :generated}, config),
    do: CachePolicy.conditional_matched(conn, config)

  defp maybe_emit_conditional_match(_conn, %Resolved{http_cache: :dialect_owned}, _config),
    do: :ok

  # `Resolved.negotiation` is a result tuple or a zero-arity thunk producing
  # one — deferred so a dialect can compute negotiation from runtime
  # geometry unavailable at prepare/3 time. Invoked only after
  # ImageSource.resolve/3 succeeds, preserving source-before-negotiation
  # error precedence.
  defp resolve_negotiation(negotiation) when is_function(negotiation, 0), do: negotiation.()
  defp resolve_negotiation(negotiation), do: negotiation

  # -- terminal dispatch (Resolved-neutral: branches on %Resolved{terminal:}) --

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: :image} = resolved,
         source,
         negotiation,
         representation,
         cache_headers,
         config
       ),
       do:
         serve(
           conn,
           dialect,
           resolved,
           source,
           negotiation,
           representation,
           cache_headers,
           config
         )

  # -- render terminal: consolidated from imgproxy /info + Native blurhash.

  # `cache: :none` bypasses the internal cache entirely and delivers through
  # `Sender`'s offers-negotiated `{:rendered, …}` path. The source's
  # `internal_cache` setting is irrelevant — the terminal already says no.
  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, %RenderTerminal{cache: :none} = terminal}},
         source,
         _negotiation,
         _representation,
         cache_headers,
         config
       ) do
    case terminal.fun.(source, config) do
      {:ok, content_type, body} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok, {:rendered, content_type, body, terminal.offers, cache_headers}},
              config
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, dialect, reason, config)
    end
  end

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, %RenderTerminal{cache: :complete_body} = terminal}},
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         _negotiation,
         _representation,
         cache_headers,
         config
       ),
       do: generate_render(conn, dialect, terminal, source, cache_headers, nil, config)

  defp serve_terminal(
         conn,
         dialect,
         %Resolved{terminal: {:render, %RenderTerminal{cache: :complete_body} = terminal}},
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         _negotiation,
         representation,
         cache_headers,
         config
       ) do
    case Cache.lookup_entry(representation.cache_key, config) do
      {:hit, %Cache.Entry{representation: {:complete_body, content_type}} = entry} ->
        deliver_render_hit(conn, terminal, content_type, entry.body, cache_headers, config)

      # A miss, a disabled cache, or an untagged entry (indistinguishable from
      # an image entry — sending one here would answer the render terminal
      # with image bytes) all regenerate.
      _miss_or_untagged ->
        generate_render(
          conn,
          dialect,
          terminal,
          source,
          cache_headers,
          representation.cache_key,
          config
        )
    end
  end

  defp deliver_render_hit(conn, %RenderTerminal{} = terminal, content_type, body, headers, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, headers, config)
    else
      conn =
        send_with_span(conn, config, :ok, fn ->
          send_complete_body(conn, content_type, body, headers, terminal.charset)
        end)

      {conn, %{result: :ok}}
    end
  end

  defp generate_render(conn, dialect, terminal, source, cache_headers, cache_key, config) do
    started_at = System.monotonic_time(:microsecond)

    case terminal.fun.(source, config) do
      {:ok, content_type, body} ->
        cost_us = System.monotonic_time(:microsecond) - started_at
        write_complete_body_cache(cache_key, content_type, body, cost_us, config)

        conn =
          send_with_span(conn, config, :ok, fn ->
            send_complete_body(conn, content_type, body, cache_headers, terminal.charset)
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

  # `charset` is the current terminal's, never the stored entry's — the cache
  # keeps a bare content type, so hit and miss present identically.
  defp send_complete_body(conn, content_type, body, %CacheHeaders{} = cache_headers, charset) do
    conn
    |> put_resp_headers(cache_headers.representation_headers)
    |> put_resp_headers(cache_headers.headers)
    |> put_body_content_type(content_type, charset)
    |> Plug.Conn.send_resp(200, body)
  end

  defp put_body_content_type(conn, content_type, :default),
    do: Plug.Conn.put_resp_content_type(conn, content_type)

  defp put_body_content_type(conn, content_type, nil),
    do: Plug.Conn.put_resp_content_type(conn, content_type, nil)

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
  end

  # negotiation.policy is nil only for Negotiation.terminal/1's render
  # terminals, which never reach generate/8 — only the image terminal
  # (Resolved{terminal: :image}) does, and its negotiation always carries a
  # policy (mirrors pipeline_opts/2's same assumption).
  defp with_policy_headers(conn, %Negotiation{policy: %Policy{headers: headers}}),
    do: put_resp_headers(conn, headers)

  # -- serve: cache dispatch (Resolved-neutral: branches on Source.Resolved) --

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         negotiation,
         _representation,
         cache_headers,
         config
       ) do
    generate(conn, dialect, resolved, source, negotiation, cache_headers, nil, config)
  end

  defp serve(
         conn,
         dialect,
         resolved,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         negotiation,
         representation,
         cache_headers,
         config
       ) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, resolved, entry, representation, cache_headers, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          dialect,
          resolved,
          source,
          negotiation,
          cache_headers,
          representation.cache_key,
          config
        )
    end
  end

  # A cache hit is the proof that a current representation exists for this
  # key — the only place `If-None-Match: *` may be honored.
  defp deliver_hit(conn, resolved, entry, representation, cache_headers, cache_serve_us, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, cache_headers, config)
    else
      deliver_hit_entry(
        conn,
        resolved,
        entry,
        representation,
        cache_headers,
        cache_serve_us,
        config
      )
    end
  end

  # A warmed `{:complete_body, content_type}` entry must NOT flow through
  # `Sender`'s image-entry delivery, which assumes an encoder output
  # (`Plan.Response.content_disposition/2` only knows the fixed image
  # delivery content types and errors on anything else).
  defp deliver_hit_entry(
         conn,
         _resolved,
         %Cache.Entry{representation: {:complete_body, content_type}} = entry,
         _representation,
         cache_headers,
         _cache_serve_us,
         config
       ) do
    conn =
      send_with_span(conn, config, :ok, fn ->
        send_complete_body(conn, content_type, entry.body, cache_headers, nil)
      end)

    {conn, %{result: :ok}}
  end

  defp deliver_hit_entry(
         conn,
         resolved,
         entry,
         representation,
         cache_headers,
         cache_serve_us,
         config
       ) do
    hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}

    conn =
      send_with_span(conn, config, :ok, fn ->
        Sender.send_result(
          conn,
          {:ok, {:cache_entry, entry, resolved.response_meta, cache_headers, hit_debug}},
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
         cache_headers,
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
              {:ok, {:prepared_stream, prepared, resolved.response_meta, cache_headers}},
              delivery_config(resolved, config)
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        # An Accept-negotiated response must carry the policy's headers
        # (Vary: Accept) even when delivery fails, or a shared cache may
        # serve the failure to a client whose Accept would have negotiated
        # a working outcome. Stamped on the conn — headers survive
        # send_resp — so render_error needs no headers argument. Only the
        # post-negotiation delivery failure carries them (mirroring every
        # dialect chain): resolve/negotiation errors stay bare.
        send_error(with_policy_headers(conn, negotiation), dialect, reason, config)
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
  #
  # Each layer converts its own failures: `execute/4` is a trusted callback
  # whose raises the runner must not launder into its tagged-tuple contract
  # (AGENTS.md), so a dialect rescues its own pipeline run and returns
  # `{:error, {:transform, _}}`. An exception escaping one of the shared
  # stages below is our bug, not the client's — it propagates to the delivery
  # session and renders 500-class rather than a misattributed 4xx.
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
        DebugBuilder.build(%DebugContext{
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

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  # `supports_hdr?` from the negotiation's own policy + plan_output — never
  # from the opaque request. Only image terminals reach this, and their
  # negotiation always carries a policy.
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

  defp encode_stop_metadata({:ok, _chunk, _ct, _stream_state, _meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    materializer = Keyword.get(config, :image_materializer, Materializer)

    case materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

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

  defp send_not_modified(conn, %CacheHeaders{} = cache_headers, config) do
    conn =
      send_with_span(conn, config, :not_modified, fn ->
        Sender.send_result(conn, {:not_modified, cache_headers}, config)
      end)

    {conn, %{result: :not_modified}}
  end

  # `%Failure{}` is unwrapped for `Error.tag/1` only — the telemetry tag names
  # the reason, not the envelope. `classify_error/1` and `render_error/3` get
  # the wrapper untouched so a dialect can act on the phase that produced it.
  defp send_error(conn, dialect, reason, config) do
    log_encode_failure(unwrap(reason))
    metadata = %{result: classify(dialect, reason), error: Error.tag(unwrap(reason))}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        dialect.render_error(conn, reason, config)
      end)

    {conn, metadata}
  end

  defp unwrap(%Failure{reason: reason}), do: reason
  defp unwrap(reason), do: reason

  # An encode failure is a server-side fault, and its telemetry tag (`:encode`)
  # keeps nothing of what actually went wrong. This is the one funnel every
  # pre-header failure passes through, and it runs before `Error.tag/1`
  # discards the exception, so the message and stacktrace are logged here —
  # once, neutrally — rather than in each dialect's error renderer.
  defp log_encode_failure({:encode, exception, stacktrace}),
    do: Logger.error("encode_error: #{Exception.format(:error, exception, stacktrace)}")

  defp log_encode_failure({:encode, :empty_stream}),
    do: Logger.error("encode_error: empty_stream")

  defp log_encode_failure(_reason), do: :ok

  defp classify(dialect, reason) do
    if function_exported?(dialect, :classify_error, 1) do
      dialect.classify_error(reason)
    else
      Telemetry.request_result({:error, reason})
    end
  end
end

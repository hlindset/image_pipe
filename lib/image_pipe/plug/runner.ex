defmodule ImagePipe.Plug.Runner do
  @moduledoc false
  require Logger

  alias ImagePipe.API
  alias ImagePipe.Cache
  alias ImagePipe.Debug
  alias ImagePipe.Debug.Info
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plug.DebugBuilder
  alias ImagePipe.Plug.Terminal
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.CachePolicy
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  @spec run(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, config) do
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, config)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, config)

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

  defp route(%Plug.Conn{method: "OPTIONS"} = conn, config) do
    conn = send_with_span(conn, config, :options, fn -> CORS.send_options(conn, config) end)
    {conn, %{result: :options}}
  end

  defp route(%Plug.Conn{method: method} = conn, config)
       when method not in ["GET", "HEAD"] do
    conn =
      send_with_span(conn, config, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp route(%Plug.Conn{} = conn, config) do
    case parse(conn, config) do
      {:ok, request} ->
        handle_request(conn, request, config)

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  defp parse(%Plug.Conn{} = conn, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      API.parse(conn, config)
    end)
  end

  defp handle_request(conn, request, config) do
    accept_header = conn |> Plug.Conn.get_req_header("accept") |> Enum.join(",")

    with {:ok, plan_source, policy} <- API.prepare(request, config, accept_header),
         {:ok, %ImageSource.Resolved{} = source} <-
           ImageSource.resolve(plan_source, config, ImageSource.runtime_opts(config)) do
      material = API.identity_material(request, policy, conn, config)

      representation =
        Representation.build(source.identity, material, source.cache_semantics.byte_identity)

      headers = cache_headers(conn, representation, source, config)

      if Conditional.not_modified?(conn, headers.etag) do
        maybe_emit_conditional_match(conn, config)
        send_not_modified(conn, headers, config)
      else
        serve_terminal(conn, request, source, policy, representation, headers, config)
      end
    else
      {:error, reason} -> send_error(conn, reason, config)
    end
  end

  defp cache_headers(conn, representation, source, config) do
    if Keyword.has_key?(config, :http_cache) do
      CachePolicy.generate(conn, representation, source_facts(source), config)
    else
      case Keyword.get(source.cache_semantics.policy, :storage, :origin) do
        :deny -> CacheHeaders.from_representation(%{representation | etag: nil, no_store?: true})
        _permission -> CacheHeaders.from_representation(representation)
      end
    end
  end

  defp source_facts(%ImageSource.Resolved{} = source) do
    %{
      http_cache: source.http_cache,
      byte_identity: source.cache_semantics.byte_identity,
      stable?: source.cache_semantics.stable?,
      storage: Keyword.get(source.cache_semantics.policy, :storage, :origin),
      adapter: source.adapter,
      source_kind: source.source_kind
    }
  end

  defp maybe_emit_conditional_match(conn, config) do
    if Keyword.has_key?(config, :http_cache), do: CachePolicy.conditional_matched(conn, config)
    :ok
  end

  defp serve_terminal(
         conn,
         %Request{output: %{terminal: :image}} = request,
         source,
         policy,
         representation,
         cache_headers,
         config
       ),
       do:
         serve(
           conn,
           request,
           source,
           policy,
           representation,
           cache_headers,
           config
         )

  defp serve_terminal(
         conn,
         %Request{} =
           request,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         _policy,
         _representation,
         cache_headers,
         config
       ),
       do:
         generate_render(
           conn,
           request,
           source,
           cache_headers,
           nil,
           config
         )

  defp serve_terminal(
         conn,
         %Request{} =
           request,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         _policy,
         representation,
         cache_headers,
         config
       ) do
    {lookup_result, cache_serve_us} =
      Timing.measure(fn -> Cache.lookup_entry(representation.cache_key, config) end)

    case lookup_result do
      {:hit, %Cache.Entry{representation: {:complete_body, _content_type}} = entry} ->
        deliver_render_hit(
          conn,
          request,
          entry,
          representation,
          cache_headers,
          cache_serve_us,
          config
        )

      # A miss, a disabled cache, or an untagged entry (indistinguishable from
      # an image entry — sending one here would answer the render terminal
      # with image bytes) all regenerate.
      _miss_or_untagged ->
        generate_render(
          conn,
          request,
          source,
          cache_headers,
          representation.cache_key,
          config
        )
    end
  end

  defp deliver_render_hit(
         conn,
         %Request{} = request,
         %Cache.Entry{representation: {:complete_body, content_type}} = entry,
         representation,
         headers,
         cache_serve_us,
         config
       ) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, headers, config)
    else
      conn =
        put_terminal_debug_headers(
          conn,
          API.response_meta(request),
          entry.debug,
          :hit,
          representation.cache_key,
          cache_serve_us,
          config
        )

      conn =
        send_with_span(conn, config, :ok, fn ->
          send_complete_body(
            conn,
            content_type,
            entry.body,
            headers,
            API.response_meta(request)
          )
        end)

      {conn, %{result: :ok}}
    end
  end

  defp generate_render(
         conn,
         %Request{} = request,
         source,
         cache_headers,
         cache_key,
         config
       ) do
    {result, cost_us} = Timing.measure(fn -> Terminal.render(source, request, config) end)

    case result do
      {:ok, content_type, body} ->
        debug = DebugBuilder.build_terminal(Executor.operation_names(request), cost_us)
        write_complete_body_cache(cache_key, content_type, body, cost_us, debug, config)

        conn =
          put_terminal_debug_headers(
            conn,
            API.response_meta(request),
            debug,
            :miss,
            cache_key,
            nil,
            config
          )

        conn =
          send_with_span(conn, config, :ok, fn ->
            send_complete_body(
              conn,
              content_type,
              body,
              cache_headers,
              API.response_meta(request)
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  defp write_complete_body_cache(
         nil = _cache_disabled,
         _content_type,
         _body,
         _cost_us,
         _debug,
         _config
       ),
       do: :ok

  defp write_complete_body_cache(
         %Cache.Key{} = cache_key,
         content_type,
         body,
         cost_us,
         %Info{} = debug,
         config
       ) do
    cache_key
    |> Cache.open_sink(
      {:complete_body, content_type},
      config
      |> Keyword.put(:cost_us, cost_us)
      |> Keyword.put(:debug_info, debug)
    )
    |> Cache.write_chunk(IO.iodata_to_binary(body), config)
    |> Cache.commit_sink(config)

    :ok
  end

  defp put_terminal_debug_headers(
         conn,
         %PlanResponse{} = response_meta,
         debug,
         cache,
         cache_key,
         cache_serve_us,
         config
       ) do
    headers =
      terminal_debug_headers(
        debug,
        cache,
        cache_key,
        cache_serve_us,
        response_meta.debug? and Keyword.get(config, :allow_debug_headers, false)
      )

    put_resp_headers(conn, headers)
  end

  defp terminal_debug_headers(_debug, _cache, _cache_key, _cache_serve_us, false), do: []
  defp terminal_debug_headers(nil, _cache, _cache_key, _cache_serve_us, true), do: []

  defp terminal_debug_headers(%Info{} = debug, cache, cache_key, cache_serve_us, true) do
    Debug.Headers.render(debug,
      cache: cache,
      cache_key: cache_key_hash(cache_key),
      cache_serve_us: cache_serve_us
    )
  end

  defp cache_key_hash(nil), do: nil
  defp cache_key_hash(%Cache.Key{hash: hash}), do: hash

  defp send_complete_body(
         conn,
         content_type,
         body,
         %CacheHeaders{} = cache_headers,
         %PlanResponse{} = response_meta
       ) do
    conn
    |> put_resp_headers(cache_headers.representation_headers)
    |> put_resp_headers(cache_headers.headers)
    |> put_complete_body_disposition(response_meta, content_type)
    |> Plug.Conn.put_resp_content_type(content_type)
    |> Plug.Conn.send_resp(200, body)
  end

  defp put_complete_body_disposition(conn, %PlanResponse{} = response_meta, content_type) do
    {:ok, content_disposition} =
      PlanResponse.content_disposition(response_meta, content_type)

    Plug.Conn.put_resp_header(conn, "content-disposition", content_disposition)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
  end

  defp with_policy_headers(conn, %Policy{headers: headers}),
    do: put_resp_headers(conn, headers)

  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :disabled} = source,
         policy,
         _representation,
         cache_headers,
         config
       ) do
    generate(conn, request, source, policy, cache_headers, nil, config)
  end

  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :enabled} = source,
         policy,
         representation,
         cache_headers,
         config
       ) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, request, entry, representation, cache_headers, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          request,
          source,
          policy,
          cache_headers,
          representation.cache_key,
          config
        )
    end
  end

  # A cache hit is the proof that a current representation exists for this
  # key — the only place `If-None-Match: *` may be honored.
  defp deliver_hit(conn, request, entry, representation, cache_headers, cache_serve_us, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, cache_headers, config)
    else
      deliver_hit_entry(
        conn,
        request,
        entry,
        representation,
        cache_headers,
        cache_serve_us,
        config
      )
    end
  end

  defp deliver_hit_entry(
         conn,
         request,
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
          {:ok, {:cache_entry, entry, API.response_meta(request), cache_headers, hit_debug}},
          delivery_config(request, config)
        )
      end)

    {conn, %{result: :ok}}
  end

  # -- image terminal: Delivery.stream over produce_stream ---------------------

  defp generate(
         conn,
         %Request{output: %{terminal: :image}} = request,
         source,
         policy,
         cache_headers,
         cache_key,
         config
       ) do
    build_fun = build_fun(request, source, policy, config)

    case Delivery.stream(self(), build_fun, cache_key, API.response_meta(request), config) do
      {:ok, prepared} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok, {:prepared_stream, prepared, API.response_meta(request), cache_headers}},
              delivery_config(request, config)
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        # An Accept-negotiated response must carry the policy's headers
        # (Vary: Accept) even when delivery fails, or a shared cache may
        # serve the failure to a client whose Accept would have negotiated
        # a working outcome. Stamped on the conn — headers survive
        # send_resp — so render_error needs no headers argument. Only the
        # post-policy delivery failure carries them (mirroring every
        # request path): resolve/policy errors stay bare.
        send_error(with_policy_headers(conn, policy), reason, config)
    end
  end

  defp build_fun(%Request{} = request, source, policy, config) do
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      decode_started_at = System.monotonic_time(:microsecond)

      Decode.with_image(
        source,
        request,
        config,
        fn state, geometry ->
          decode_us = System.monotonic_time(:microsecond) - decode_started_at

          try do
            produce_stream(
              state,
              geometry,
              request,
              policy,
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

  defp produce_stream(state, geometry, request, policy, config, pump, decode_us) do
    shrink = state.decode_shrink

    with {{:ok, %State{} = state}, transform_us} <-
           Timing.measure(fn ->
             run_transform(state, geometry, request, policy, config)
           end),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(policy, geometry.source_format, state.image, config),
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
           Timing.measure(fn ->
             encode_first_chunk(image, resolved_output, state.source_color_profile, config)
           end) do
      debug =
        DebugBuilder.build(%{
          geometry: geometry,
          shrink: shrink,
          policy: policy,
          resolved_output: resolved_output,
          image: image,
          search_meta: search_meta,
          operations: Executor.operation_names(request),
          timings: %{decode: decode_us, transform: transform_us, encode: encode_us}
        })

      pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, debug)
    else
      {:empty, _microseconds} -> {:error, {:encode, :empty_stream}}
      {{:error, _reason} = error, _microseconds} -> error
      {:error, _reason} = error -> error
    end
  end

  defp run_transform(state, geometry, %Request{} = request, policy, config) do
    operations = Executor.operation_names(request)

    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: operations, operation_count: length(operations)},
      fn ->
        result =
          Executor.execute(
            state,
            request,
            pipeline_opts(policy, geometry, config)
          )

        {result, transform_stop_metadata(result)}
      end
    )
  end

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp pipeline_opts(%Policy{} = policy, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(policy, geometry.source_format)
    )
  end

  defp resolve_output(policy, source_format, image, config) do
    Policy.negotiate(
      policy,
      source_format,
      image,
      Telemetry.telemetry_opts(config)
    )
  end

  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, source_profile, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, source_profile, config),
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

  defp delivery_config(%Request{} = request, config) do
    Keyword.put(
      config,
      :debug?,
      request.debug? and Keyword.get(config, :allow_debug_headers, false)
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

  defp send_error(conn, reason, config) do
    log_encode_failure(reason)
    metadata = %{result: API.classify_error(reason), error: Error.tag(reason)}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        API.render_error(conn, reason)
      end)

    {conn, metadata}
  end

  # An encode failure is a server-side fault, and its telemetry tag (`:encode`)
  # keeps nothing of what actually went wrong. This is the one funnel every
  # pre-header failure passes through, and it runs before `Error.tag/1`
  # discards the exception, so the message and stacktrace are logged here —
  # once before sending the error response.
  defp log_encode_failure({:encode, exception, stacktrace}),
    do: Logger.error("encode_error: #{Exception.format(:error, exception, stacktrace)}")

  defp log_encode_failure({:encode, :empty_stream}),
    do: Logger.error("encode_error: empty_stream")

  defp log_encode_failure(_reason), do: :ok
end

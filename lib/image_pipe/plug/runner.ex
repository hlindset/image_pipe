defmodule ImagePipe.Plug.Runner do
  @moduledoc false
  require Logger

  alias ImagePipe.API
  alias ImagePipe.Cache
  alias ImagePipe.Debug
  alias ImagePipe.Debug.Info
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Delivery
  alias ImagePipe.Error
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plug.SourceCache
  alias ImagePipe.Plug.Terminal
  alias ImagePipe.Processing
  alias ImagePipe.Processing.DebugBuilder
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.CachePolicy
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Executor

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
      serve_resolved(conn, request, source, policy, material, config)
    else
      {:error, reason} -> send_error(conn, reason, config)
    end
  end

  defp serve_resolved(conn, request, source, policy, material, config) do
    case SourceCache.enabled?(source, config) do
      true ->
        prepare_remote(conn, request, source, policy, material, config)

      false ->
        representation =
          Representation.build(source.identity, material, source.cache_semantics.byte_identity)

        headers = cache_headers(conn, representation, source, config)

        case Conditional.not_modified?(conn, headers.etag) do
          true ->
            maybe_emit_conditional_match(conn, config)
            send_not_modified(conn, headers, config)

          false ->
            serve_terminal(conn, request, source, policy, representation, headers, config)
        end
    end
  end

  defp prepare_remote(conn, request, source, policy, material, config) do
    case ImageSource.prepare_cache_context(source, config) do
      {:ok, source, context} ->
        key = Representation.input_key(source.identity, material, context)

        material = %{
          material
          | storage_only: [{:source_partition, key.hash} | material.storage_only]
        }

        remote_request(%{
          conn: conn,
          request: request,
          source: source,
          policy: policy,
          material: material,
          key: key,
          config: config
        })

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  defp remote_request(ctx) do
    record =
      SourceCache.trusted_record(ctx.source, ctx.config) ||
        SourceCache.lookup(ctx.source, ctx.key, ctx.config)

    case SourceCache.status(record, ctx.source, ctx.config) do
      :fresh -> remote_current(ctx, record, nil)
      :stale -> remote_stale(ctx, record)
      _validate -> remote_validate(ctx, record)
    end
  end

  defp remote_validate(ctx, record) do
    case SourceCache.acquire(ctx.source, ctx.key, record, ctx.config, false) do
      {:ok, current, response, lease} -> remote_leased(ctx, current, response, lease)
      {:error, reason} -> send_error(ctx.conn, reason, ctx.config)
    end
  end

  defp remote_leased(ctx, record, response, lease) do
    remote_current(ctx, record, response)
  after
    SourceCache.release(lease)
  end

  defp remote_current(ctx, record, response) do
    {representation, headers} = remote_identity(ctx, record)

    case Conditional.not_modified?(ctx.conn, headers.etag) do
      true ->
        maybe_emit_conditional_match(ctx.conn, ctx.config)
        send_not_modified(ctx.conn, headers, ctx.config)

      false ->
        case remote_lookup(ctx, record, representation) do
          {:hit, entry} -> remote_hit(ctx, entry, representation, headers, record)
          _miss -> remote_input(ctx, record, response)
        end
    end
  end

  defp remote_lookup(ctx, record, representation) do
    case SourceCache.storable?(record, ctx.source) do
      true -> Cache.lookup_entry(representation.cache_key, ctx.config)
      false -> :disabled
    end
  end

  defp remote_hit(ctx, entry, representation, headers, record) do
    case {ctx.request.output.terminal, entry.representation} do
      {:image, _image} ->
        deliver_hit(ctx.conn, ctx.request, entry, representation, headers, 0, ctx.config)

      {_terminal, {:complete_body, _type}} ->
        deliver_render_hit(ctx.conn, ctx.request, entry, representation, headers, 0, ctx.config)

      _invalid ->
        Cache.Entry.close(entry)
        remote_input(ctx, record, nil)
    end
  end

  defp remote_input(ctx, record, nil) do
    case SourceCache.input(ctx.source, ctx.key, record, ctx.config) do
      {:ok, record, response, lease} -> remote_generate_leased(ctx, record, response, lease)
      {:error, reason} -> send_error(ctx.conn, reason, ctx.config)
    end
  end

  defp remote_input(ctx, record, response), do: remote_generate(ctx, record, response)

  defp remote_generate_leased(ctx, record, response, lease) do
    remote_generate(ctx, record, response)
  after
    SourceCache.release(lease)
  end

  defp remote_generate(ctx, record, response) do
    {representation, headers} = remote_identity(ctx, record)

    config =
      ctx.config |> Keyword.put(:prepared_source, response) |> Keyword.put(:source_record, record)

    key =
      case SourceCache.storable?(record, ctx.source) do
        true -> representation.cache_key
        false -> nil
      end

    result =
      case ctx.request.output.terminal do
        :image -> generate(ctx.conn, ctx.request, ctx.source, ctx.policy, headers, key, config)
        _terminal -> generate_render(ctx.conn, ctx.request, ctx.source, headers, key, config)
      end

    case result do
      {%Plug.Conn{status: 415}, _metadata} -> SourceCache.invalidate(ctx.key, ctx.config)
      _result -> :ok
    end

    result
  end

  defp remote_identity(ctx, record) do
    representation = Representation.build(ctx.source.identity, ctx.material, record.byte_identity)

    source = %{
      ctx.source
      | cache_semantics: %{ctx.source.cache_semantics | byte_identity: record.byte_identity}
    }

    state = ImageSource.Record.state(record, source.cache_semantics)
    headers = cache_headers(ctx.conn, representation, source, ctx.config)
    now = SourceCache.now(ctx.config)

    age =
      case record.origin do
        nil ->
          max(0, now - record.received_at)

        origin ->
          ImageSource.CacheState.current_age(
            origin.headers,
            {origin.requested_at, origin.received_at},
            now
          )
      end

    headers =
      CachePolicy.limit_to_source(headers, ctx.conn, Map.put(state, :age, age), now, ctx.config)

    {representation, headers}
  end

  defp remote_stale(ctx, record) do
    case Keyword.get(ctx.config, :cache_refresh, false) do
      true ->
        remote_validate(ctx, record)

      false ->
        {representation, headers} = remote_identity(ctx, record)

        case remote_lookup(ctx, record, representation) do
          {:hit, entry} ->
            start_refresh(ctx, representation)
            stale_hit(ctx, entry, representation, headers, record)

          _miss ->
            remote_validate(ctx, record)
        end
    end
  end

  defp stale_hit(ctx, entry, representation, headers, record) do
    case Conditional.not_modified?(ctx.conn, headers.etag) do
      true ->
        Cache.Entry.close(entry)
        send_not_modified(ctx.conn, headers, ctx.config)

      false ->
        remote_hit(ctx, entry, representation, headers, record)
    end
  end

  defp start_refresh(ctx, representation) do
    Cache.Work.refresh(
      {:output, representation.cache_key.hash},
      fn ->
        Telemetry.span(
          Telemetry.telemetry_opts(ctx.config),
          [:cache, :refresh],
          %{pool: :input},
          fn ->
            {_conn, metadata} = result = refresh_remote(ctx)
            {result, metadata}
          end
        )
      end,
      Telemetry.telemetry_opts(ctx.config)
    )
  end

  defp refresh_remote(ctx) do
    conn = %{
      ctx.conn
      | adapter: {ImagePipe.Response.Discard, nil},
        owner: self(),
        state: :unset,
        status: nil,
        resp_body: nil,
        resp_headers: [],
        resp_cookies: %{},
        private: %{},
        method: "GET",
        req_headers:
          Enum.reject(ctx.conn.req_headers, fn {name, _} ->
            name in ["if-none-match", "if-modified-since"]
          end)
    }

    remote_request(%{ctx | conn: conn, config: Keyword.put(ctx.config, :cache_refresh, true)})
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

      miss_or_untagged ->
        case miss_or_untagged do
          {:hit, entry} -> Cache.Entry.close(entry)
          _miss -> :ok
        end

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
  after
    Cache.Entry.close(entry)
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
    |> Sender.send_body(body)
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
  after
    Cache.Entry.close(entry)
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
    build_fun = Processing.build_fun(request, source, policy, config)

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

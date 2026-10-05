defmodule ImagePipe.Plug.Runner do
  @moduledoc false
  require Logger

  alias ImagePipe.API.Parser
  alias ImagePipe.Error
  alias ImagePipe.Execution
  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plug.Errors
  alias ImagePipe.Plug.Request, as: ParsedRequest
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.CachePolicy
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry

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
    |> abort_failed_stream()
  end

  # Returning the conn lets the server end the body as if it were complete.
  # Raising makes it drop the connection instead, so clients and CDNs see the
  # truncation. A cached body that failed in the adapter may have had its
  # headers written even though the conn still reads as unsent.
  defp abort_failed_stream(
         %Plug.Conn{private: %{image_pipe_send_result: :processing_error}} = conn
       ),
       do: raise_abort(conn.adapter, Plug.Conn.get_http_protocol(conn))

  defp abort_failed_stream(conn), do: conn

  # Workaround for Bandit #703 (https://github.com/mtrudel/bandit/issues/703):
  # over HTTP/2, Bandit leaves a stream open when the plug raises after the
  # response started, so the client hangs. Only its internal StreamError makes
  # it send RST_STREAM. Bandit is not a dependency, hence the runtime module
  # name. Delete this clause once Bandit resets the stream itself.
  defp raise_abort({Bandit.Adapter, _adapter}, :"HTTP/2") do
    stream_error = Module.concat(["Bandit", "HTTP2", "Errors", "StreamError"])

    raise stream_error,
      message: "image response failed after its headers were sent",
      error_code: 0x2
  end

  defp raise_abort(_adapter, _protocol), do: raise(ImagePipe.Plug.StreamAbortedError)

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
      {:ok, request, source} ->
        handle_request(conn, request, source, config)

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  defp parse(%Plug.Conn{} = conn, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      ParsedRequest.parse(conn, config)
    end)
  end

  defp handle_request(conn, request, source, config) do
    conn = report_ignored_options(conn, request, config)
    accept = conn |> Plug.Conn.get_req_header("accept") |> Enum.join(",")
    conn = Plug.Conn.fetch_cookies(conn)
    inputs = %Inputs{headers: conn.req_headers, cookies: conn.req_cookies}

    with {:ok, plan_source, watermarks, policy} <-
           ParsedRequest.prepare(request, source, config, accept),
         {:ok, source} <-
           ImageSource.resolve(plan_source, config, ImageSource.runtime_opts(config)),
         {:ok, context} <-
           Execution.prepare(request, source, watermarks, policy, inputs, config) do
      try do
        serve_context(conn, context)
      after
        Execution.close(context)
      end
    else
      {:error, reason} -> send_error(conn, reason, config)
    end
  end

  # The headers built here only answer an early 304, so a request without
  # `If-None-Match` skips them. `serve_output/2` builds the response's own.
  defp serve_context(conn, context) do
    headers = not context.stale? and conditional?(conn) and context_headers(conn, context)

    case headers && Conditional.not_modified?(conn, headers.etag) do
      true ->
        send_not_modified(conn, headers, context.config)

      _no_early_match ->
        case Execution.open(context) do
          {:ok, output} ->
            serve_output(conn, output)

          {:error, reason} ->
            send_error(with_policy_headers(conn, context.policy), reason, context.config)
        end
    end
  end

  defp conditional?(conn), do: Plug.Conn.get_req_header(conn, "if-none-match") != []

  defp serve_output(conn, output) do
    context = output.context
    headers = context_headers(conn, context, output.degraded?)

    case output.cache == :hit and
           (Conditional.if_none_match_wildcard?(conn) or
              Conditional.not_modified?(conn, headers.etag)) do
      true -> send_not_modified(conn, headers, context.config)
      false -> deliver(conn, output, headers)
    end
  after
    Execution.close_output(output)
  end

  defp context_headers(conn, context, degraded? \\ false) do
    source = %{context.source | cache_semantics: Execution.cache_semantics(context)}

    mode = CachePolicy.mode(source.http_cache, context.config)

    headers =
      CachePolicy.generate(
        conn,
        context.representation,
        source_facts(source),
        mode,
        context.config,
        degraded?
      )

    headers =
      case Execution.source_state(context) do
        nil ->
          headers

        {state, now} ->
          CachePolicy.limit_to_source(headers, conn, state, now, mode, context.config)
      end

    CachePolicy.limit_to_expiry(
      headers,
      conn,
      context.request.expires,
      Keyword.fetch!(context.config, :clock).(),
      mode,
      context.config
    )
  end

  defp deliver(
         conn,
         %{value: {:entry, %{representation: {:complete_body, type}} = entry}} = output,
         headers
       ),
       do: deliver_body(conn, output, headers, type, entry.body, entry.debug)

  defp deliver(conn, %{value: {:body, body, type, debug}} = output, headers),
    do: deliver_body(conn, output, headers, type, body, debug)

  defp deliver(conn, output, headers) do
    context = output.context

    conn =
      send_with_span(conn, context.config, :ok, fn ->
        config = delivery_config(context.request, context.config)

        case output.value do
          {:entry, entry} ->
            debug = %{
              cache_key: context.representation.cache_key.hash,
              cache_serve_us: output.cache_us
            }

            Sender.send_cache_entry(conn, entry, context.request, headers, debug, config)

          {:stream, stream} ->
            Sender.send_prepared_stream(conn, stream, context.request, headers, config)
        end
      end)

    {conn, %{result: :ok}}
  end

  defp deliver_body(conn, output, headers, type, body, debug) do
    context = output.context

    conn =
      send_with_span(conn, context.config, :ok, fn ->
        Sender.send_complete_body(
          conn,
          type,
          body,
          headers,
          context.request,
          debug,
          [
            cache: output.cache,
            cache_key: context.representation.cache_key.hash,
            cache_serve_us: output.cache_us
          ],
          delivery_config(context.request, context.config)
        )
      end)

    {conn, %{result: :ok}}
  end

  defp source_facts(%ImageSource.Resolved{} = source) do
    %{
      byte_identity: source.cache_semantics.byte_identity,
      stable?: source.cache_semantics.stable?,
      storage: Keyword.get(source.cache_semantics.policy, :storage, :origin),
      source_name: source.name
    }
  end

  defp with_policy_headers(conn, %Policy{headers: headers}) do
    Enum.reduce(headers, conn, fn
      {"vary", value}, acc ->
        Plug.Conn.put_resp_header(
          acc,
          "vary",
          CacheHeaders.merge_vary(acc, CacheHeaders.split_vary(value))
        )

      {name, value}, acc ->
        Plug.Conn.put_resp_header(acc, name, value)
    end)
  end

  defp with_policy_headers(conn, nil), do: conn

  defp report_ignored_options(conn, %Spec{ignored: []}, _config), do: conn

  defp report_ignored_options(conn, %Spec{} = request, config) do
    keys = Parser.ignored_keys(request)
    Telemetry.ignored_options(Telemetry.telemetry_opts(config), keys, request.ignored)

    case delivery_config(request, config)[:debug?] do
      true -> Plug.Conn.put_resp_header(conn, "x-imagepipe-ignored-options", Enum.join(keys, ","))
      false -> conn
    end
  end

  defp delivery_config(%Spec{} = request, config) do
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
    CachePolicy.conditional_matched(conn, config)

    conn =
      send_with_span(conn, config, :not_modified, fn ->
        Sender.send_not_modified(conn, cache_headers)
      end)

    {conn, %{result: :not_modified}}
  end

  defp send_error(conn, reason, config) do
    log_encode_failure(reason)
    metadata = %{result: Telemetry.request_result({:error, reason}), error: Error.tag(reason)}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Errors.send(conn, reason)
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

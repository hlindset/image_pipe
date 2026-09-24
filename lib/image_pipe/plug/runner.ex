defmodule ImagePipe.Plug.Runner do
  @moduledoc false
  require Logger

  alias ImagePipe.API
  alias ImagePipe.Error
  alias ImagePipe.Execution
  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Request
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
    accept = conn |> Plug.Conn.get_req_header("accept") |> Enum.join(",")
    conn = Plug.Conn.fetch_cookies(conn)
    inputs = %Inputs{headers: conn.req_headers, cookies: conn.req_cookies}

    with {:ok, plan_source, policy} <- API.prepare(request, config, accept),
         {:ok, source} <-
           ImageSource.resolve(plan_source, config, ImageSource.runtime_opts(config)),
         {:ok, context} <- Execution.prepare(request, source, policy, inputs, config) do
      try do
        serve_context(conn, context)
      after
        Execution.close(context)
      end
    else
      {:error, reason} -> send_error(conn, reason, config)
    end
  end

  defp serve_context(conn, context) do
    headers = context_headers(conn, context)

    case not context.stale? and Conditional.not_modified?(conn, headers.etag) do
      true ->
        maybe_emit_conditional_match(conn, context.config)
        send_not_modified(conn, headers, context.config)

      false ->
        case Execution.open(context) do
          {:ok, output} ->
            serve_output(conn, output)

          {:error, reason} ->
            send_error(with_policy_headers(conn, context.policy), reason, context.config)
        end
    end
  end

  defp serve_output(conn, output) do
    context = output.context
    headers = context_headers(conn, context)

    case output.cache == :hit and
           (Conditional.if_none_match_wildcard?(conn) or
              Conditional.not_modified?(conn, headers.etag)) do
      true -> send_not_modified(conn, headers, context.config)
      false -> deliver(conn, output, headers)
    end
  after
    Execution.close_output(output)
  end

  defp context_headers(conn, context) do
    source =
      case context.acquisition.record do
        nil ->
          context.source

        record ->
          %{
            context.source
            | cache_semantics: %{
                context.source.cache_semantics
                | byte_identity: record.byte_identity
              }
          }
      end

    headers = cache_headers(conn, context.representation, source, context.config)

    case Execution.source_state(context) do
      nil -> headers
      {state, now} -> CachePolicy.limit_to_source(headers, conn, state, now, context.config)
    end
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

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      Plug.Conn.put_resp_header(acc, name, value)
    end)
  end

  defp with_policy_headers(conn, %Policy{headers: headers}),
    do: put_resp_headers(conn, headers)

  defp with_policy_headers(conn, nil), do: conn

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
        Sender.send_not_modified(conn, cache_headers)
      end)

    {conn, %{result: :not_modified}}
  end

  defp send_error(conn, reason, config) do
    log_encode_failure(reason)
    metadata = %{result: Telemetry.request_result({:error, reason}), error: Error.tag(reason)}

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

defmodule ImagePipe.Plug do
  @moduledoc """
  Plug entry point for fetching, transforming, caching, and encoding images.
  """

  use Boundary,
    deps: [
      ImagePipe.Error,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Request,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Error
  alias ImagePipe.Parser
  alias ImagePipe.Plan
  alias ImagePipe.Request.HTTPCache
  alias ImagePipe.Request.Options
  alias ImagePipe.Request.Runner
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  @impl Plug
  def init(opts) do
    opts
    |> Options.validate!()
    |> validate_parser_options()
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    Telemetry.Trace.maybe_extract_inbound(conn)

    Telemetry.span(telemetry_opts, [:request], request_metadata(conn, opts), fn ->
      {conn, metadata} = do_call(conn, opts)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  defp do_call(%Plug.Conn{method: method} = conn, opts) when method not in ["GET", "HEAD"] do
    {conn, _send_metadata} =
      send_response(conn, opts, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp do_call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    case parse(conn, parser, opts) do
      {:redirect, status, location} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :redirect, fn ->
            Sender.send_redirect(conn, status, location)
          end)

        {conn, %{result: :redirect, status: status}}

      parsed ->
        do_call_with_plan(conn, parser, opts, parsed)
    end
  end

  defp do_call_with_plan(conn, parser, opts, parsed) do
    with {:ok, %Plan{} = plan} <- parsed,
         {:ok, %Plan{} = plan} <- validate_client_plan(plan),
         :ok <- validate_detector_capability(plan, opts),
         {:ok, %Source.Resolved{} = resolved_source} <-
           Source.resolve(plan.source, opts, Options.source_runtime_opts(opts)) do
      prepared_http_cache = HTTPCache.prepare(conn, plan, resolved_source, opts)
      send_conditional_response(conn, plan, resolved_source, prepared_http_cache, opts)
    else
      {:error, {:parser, error}} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :parser_error, fn -> parser.handle_error(conn, error) end)

        {conn, %{result: :parser_error, error: Error.tag(error)}}

      {:error, {:plan_validation, error}} ->
        result = {:error, {:processing, error, []}}

        {conn, _send_metadata} =
          send_response(conn, opts, :plan_error, fn -> Sender.send_result(conn, result, opts) end)

        {conn, %{result: :plan_error, error: Error.tag(error)}}

      {:error, {:detector, :unavailable} = error} ->
        result = {:error, {:processing, {:detector_unavailable, :unavailable}, []}}

        {conn, _send_metadata} =
          send_response(conn, opts, :plan_error, fn -> Sender.send_result(conn, result, opts) end)

        {conn, %{result: :plan_error, error: Error.tag(error)}}

      {:error, {:source, error}} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error) end)

        {conn, %{result: :source_error, error: Error.tag(error)}}
    end
  end

  defp send_conditional_response(conn, plan, resolved_source, prepared_http_cache, opts) do
    case HTTPCache.evaluate_conditional(conn, prepared_http_cache, opts) do
      {:not_modified, prepared} ->
        result = :not_modified

        {conn, send_metadata} =
          send_response(conn, opts, result, fn ->
            Sender.send_not_modified(conn, prepared)
          end)

        {conn, request_stop_metadata(result, send_metadata)}

      :proceed ->
        result = Runner.run(conn, plan, resolved_source, prepared_http_cache, opts)

        {conn, send_metadata} =
          send_response(conn, opts, request_result(result), fn ->
            Sender.send_result(conn, result, opts)
          end)

        {conn, request_stop_metadata(result, send_metadata)}
    end
  end

  defp parse(conn, parser, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:parse], request_metadata(conn, opts), fn ->
      result = parser.parse(conn, opts) |> wrap_parser_error()

      {result, result_metadata(result)}
    end)
  end

  defp send_response(_conn, opts, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:send], %{result: result}, fn ->
      sent_conn = fun.()
      metadata = send_stop_metadata(sent_conn, result)

      {{sent_conn, metadata}, metadata}
    end)
  end

  defp validate_client_plan(%Plan{} = plan) do
    with {:ok, _pipelines} <- Transform.validate_prefetch_safe_plan(plan) do
      {:ok, plan}
    end
    |> wrap_plan_validation_error()
  end

  # Strict-mode capability gate: when the host opts into `detector_required` and
  # the plan asks for content detection (`g:obj:face` -> a `{:detect, _}` guide),
  # reject up-front if the configured detector is unavailable. Availability is a
  # cheap `Code.ensure_loaded?`-style check (no I/O), so this runs before any
  # source fetch or cache access rather than silently degrading to attention.
  defp validate_detector_capability(%Plan{} = plan, opts) do
    classes = Plan.detect_classes(plan)

    if Keyword.get(opts, :detector_required, false) and classes != nil do
      opts_with_classes = Keyword.put(opts, :classes, classes)

      if Transform.detector_available?(Keyword.get(opts, :detector, :default), opts_with_classes),
        do: :ok,
        else: {:error, {:detector, :unavailable}}
    else
      :ok
    end
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_plan_validation_error({:error, error}), do: {:error, {:plan_validation, error}}
  defp wrap_plan_validation_error(result), do: result

  defp request_metadata(conn, opts) do
    %{
      parser: Keyword.fetch!(opts, :parser),
      request_method: conn.method
    }
  end

  defp send_stop_metadata(%Plug.Conn{} = conn, result) do
    %{
      result: Map.get(conn.private, :image_pipe_send_result, result),
      status: conn.status
    }
  end

  defp request_stop_metadata(result, send_metadata) do
    result
    |> request_result_metadata()
    |> Map.merge(send_metadata)
  end

  defp request_result({:ok, _delivery}), do: :ok
  defp request_result({:error, {:processing, reason, _headers}}), do: processing_result(reason)

  defp request_result_metadata(:not_modified), do: %{result: :not_modified}
  defp request_result_metadata({:ok, _delivery}), do: %{result: :ok}

  defp request_result_metadata({:error, {:processing, reason, _headers}}),
    do: %{result: processing_result(reason), error: processing_error_tag(reason)}

  defp processing_result({:source, _error}), do: :source_error
  defp processing_result({:cache_write, _error}), do: :cache_error

  defp processing_result({tag, _error})
       when tag in [:invalid_output_plan, :invalid_pipeline_plan],
       do: :plan_error

  defp processing_result(:empty_pipeline_plan), do: :plan_error
  defp processing_result(_reason), do: :processing_error

  defp processing_error_tag({:source, error}), do: Error.tag(error)
  defp processing_error_tag({:cache_write, error}), do: Error.tag(error)

  defp processing_error_tag({tag, _error})
       when tag in [:invalid_output_plan, :invalid_pipeline_plan],
       do: tag

  defp processing_error_tag(reason), do: Error.tag(reason)

  defp result_metadata({:ok, _value}), do: %{result: :ok}

  defp result_metadata({:redirect, status, _location}), do: %{result: :redirect, status: status}

  defp result_metadata({:error, {_scope, error}}),
    do: %{result: :error, error: Error.tag(error)}

  defp validate_parser_options(opts) do
    opts
    |> Keyword.fetch!(:parser)
    |> Parser.validate_options!(opts)
  end
end

defmodule ImagePipe.Run do
  @moduledoc false

  alias ImagePipe.Error
  alias ImagePipe.Plan
  alias ImagePipe.Processing
  alias ImagePipe.Processing.Config
  alias ImagePipe.Processing.Terminal
  alias ImagePipe.Result
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  def run(plan, input, options) do
    {accept, options} = Keyword.pop(options, :accept, "")
    unless is_binary(accept), do: raise(ArgumentError, "accept must be a string")
    config = Config.validate!(options)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      result = execute(plan, input, config, accept)
      {result, request_metadata(result)}
    end)
  end

  def write(plan, input, destination, options) do
    with {:ok, result} <- run(plan, input, options),
         :ok <- write_result(result, destination) do
      {:ok, result}
    end
  end

  defp execute(plan, input, config, accept) do
    with {:ok, request} <- request(plan),
         {:ok, policy} <- Processing.prepare(request, config, accept),
         {:ok, source, config} <- Source.from_input(input, config) do
      render(source, request, policy, config)
    end
  end

  defp request(plan) do
    case Plan.to_request(plan, "") do
      {:ok, request} -> {:ok, request}
      {:error, issues} -> {:error, {:invalid_request, issues}}
    end
  end

  defp render(source, %{output: %{terminal: :image}} = request, policy, config) do
    with {:ok, data, content_type, format, {width, height}} <-
           Processing.buffer(request, source, policy, config) do
      {:ok,
       %Result{
         terminal: :image,
         data: data,
         content_type: content_type,
         format: format,
         width: width,
         height: height
       }}
    end
  end

  defp render(source, request, _policy, config) do
    with {:ok, content_type, data} <- Terminal.render(source, request, config) do
      {:ok, %Result{terminal: request.output.terminal, content_type: content_type, data: data}}
    end
  end

  defp write_result(%Result{terminal: :info, data: data}, path),
    do: write_bytes(JSON.encode_to_iodata!(data), path)

  defp write_result(%Result{data: data}, path), do: write_bytes(data, path)

  defp write_bytes(data, path) do
    case File.write(path, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:destination, reason}}
    end
  end

  defp request_metadata({:ok, _result}), do: %{result: :ok}
  defp request_metadata({:error, {:invalid_request, _issues}}), do: %{result: :parser_error}
  defp request_metadata({:error, :expired}), do: %{result: :parser_error}
  defp request_metadata({:error, {:invalid_output, _reason}}), do: %{result: :plan_error}
  defp request_metadata({:error, {:detector, :unavailable}}), do: %{result: :plan_error}

  defp request_metadata({:error, reason} = error),
    do: %{result: Telemetry.request_result(error), error: Error.tag(reason)}
end

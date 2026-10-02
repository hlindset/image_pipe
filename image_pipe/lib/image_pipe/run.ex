defmodule ImagePipe.Run do
  @moduledoc false

  alias ImagePipe.Config
  alias ImagePipe.Error
  alias ImagePipe.Execution
  alias ImagePipe.Execution.Inputs
  alias ImagePipe.Execution.Output
  alias ImagePipe.Format
  alias ImagePipe.Plan
  alias ImagePipe.Presets
  alias ImagePipe.Processing
  alias ImagePipe.Result
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  def run(%Config{} = shared, %ImagePipe.URL{plan: plan}, input, options) do
    {accept, options} = Keyword.pop(options, :accept, "")
    unless is_binary(accept), do: raise(ArgumentError, "accept must be a string")
    {request_inputs, options} = Keyword.pop(options, :request_inputs, [])
    inputs = Inputs.new!(request_inputs)
    config = Config.override(shared, options).options

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      result = execute(plan, input, config, accept, inputs)
      {result, request_metadata(result)}
    end)
  end

  def write(config, builder, input, destination, options) do
    with {:ok, result} <- run(config, builder, input, options),
         :ok <- write_result(result, destination) do
      {:ok, result}
    end
  end

  defp execute(plan, input, config, accept, inputs) do
    with {:ok, request} <- request(plan, config),
         {:ok, policy} <- Processing.prepare(request, config, accept),
         {:ok, watermarks} <- Execution.watermark_sources(request, config),
         {:ok, source, config} <- Source.from_input(input, config),
         {:ok, context} <- Execution.prepare(request, source, watermarks, policy, inputs, config) do
      try do
        render(context)
      after
        Execution.close(context)
      end
    end
  end

  defp request(plan, config) do
    watermarks = %{
      names: Map.keys(config[:watermarks]),
      request_sources?: config[:request_watermarks]
    }

    names = Plan.preset_names(plan)

    with {:ok, presets} <- Presets.for_request(names, config) do
      case Plan.to_spec(plan, presets, config[:request_defaults], watermarks) do
        {:ok, request} -> {:ok, request}
        {:error, issues} -> {:error, {:invalid_request, issues}}
      end
    end
  end

  def validate(%Config{} = shared, %ImagePipe.URL{plan: plan}) do
    config = shared.options

    with {:ok, request} <- request(plan, config),
         {:ok, _policy} <- Processing.prepare(request, config, ""),
         do: :ok
  end

  defp render(context) do
    with {:ok, output} <- Execution.open(context) do
      try do
        with {:ok, data, type, debug} <- Output.buffer(output) do
          result(context.request.output.terminal, data, type, debug)
        end
      after
        Execution.close_output(output)
      end
    end
  end

  defp result(:image, data, content_type, debug) do
    with {:ok, format} <- format(content_type),
         {:ok, {width, height}} <- dimensions(data, debug) do
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

  defp result(:info, data, content_type, _debug) do
    case JSON.decode(data) do
      {:ok, info} when is_map(info) ->
        {:ok, %Result{terminal: :info, content_type: content_type, data: info}}

      _invalid ->
        {:error, {:decode, :invalid_cached_info}}
    end
  end

  defp result(terminal, data, content_type, _debug),
    do: {:ok, %Result{terminal: terminal, content_type: content_type, data: data}}

  # A skipped source keeps its own format, which may be a source-only one.
  defp format(content_type) do
    case Enum.find(Format.source_formats(), &(Format.mime_type!(&1) == content_type)) do
      nil -> {:error, {:unsupported_output_format, content_type}}
      format -> {:ok, format}
    end
  end

  defp dimensions(_data, %{output_width: width, output_height: height})
       when is_integer(width) and is_integer(height), do: {:ok, {width, height}}

  defp dimensions(data, _debug) do
    case Image.from_binary(data) do
      {:ok, image} -> {:ok, {Image.width(image), Image.height(image)}}
      {:error, reason} -> {:error, {:decode, reason}}
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

  defp request_metadata({:error, reason} = error) do
    case Telemetry.request_result(error) do
      result when result in [:parser_error, :plan_error] -> %{result: result}
      result -> %{result: result, error: Error.tag(reason)}
    end
  end
end

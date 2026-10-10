defmodule ImagePipe.Run do
  @moduledoc false

  alias ImagePipe.API.Parser
  alias ImagePipe.Config
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

  @options_schema NimbleOptions.new!(
                    accept: [
                      type: :string,
                      default: "",
                      doc: """
                      An HTTP `Accept` value, such as `"image/avif,image/webp"`, for \
                      choosing the output format when the plan has no `format`. An \
                      empty value keeps the original's format where possible, as for a \
                      request without `Accept` (see \
                      [output formats](requesting-images.md#output-formats)). \
                      `:auto_avif`, `:auto_webp`, and `:format_order` apply as configured.
                      """
                    ],
                    request_inputs: [
                      type: :keyword_list,
                      keys: Inputs.schema(),
                      default: [],
                      doc: """
                      The header and cookie values named by the configuration's \
                      `:storage_inputs`, for `{:source, source}` inputs. They select the \
                      same stored copy as those values in an HTTP request. Header names \
                      are case-insensitive, and cookie names are case-sensitive. A \
                      missing value matches a request without it. They aren't sent to \
                      the source and don't change the result.
                      """
                    ]
                  )

  @doc false
  def options_docs, do: NimbleOptions.docs(@options_schema)

  def run(%Config{} = shared, %ImagePipe.URL{plan: plan}, input, options) do
    {run_options, options} = Keyword.split(options, [:accept, :request_inputs])

    {accept, inputs} =
      case NimbleOptions.validate(run_options, @options_schema) do
        {:ok, valid} -> {valid[:accept], Inputs.new(valid[:request_inputs])}
        {:error, error} -> raise ArgumentError, "invalid run options: #{Exception.message(error)}"
      end

    %Config{options: config} =
      shared |> Config.override(options) |> Config.reject_unsupervised_processes!()

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
         :ok <- report_ignored_options(request, config),
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

  defp report_ignored_options(%{ignored: []}, _config), do: :ok

  defp report_ignored_options(request, config) do
    Telemetry.ignored_options(
      Telemetry.telemetry_opts(config),
      Parser.ignored_keys(request),
      request.ignored
    )
  end

  defp request(plan, config) do
    watermarks = %{
      names: Map.keys(config[:watermarks]),
      request_sources?: config[:request_watermarks]
    }

    names = Plan.preset_names(plan)

    # The builder's own errors need no lookup, so they return before one.
    with {:ok, _warnings} <- built(plan),
         {:ok, presets} <- Presets.for_request(names, config) do
      case Plan.to_spec(plan, presets, config[:request_defaults], watermarks) do
        {:ok, request} -> {:ok, request}
        {:error, issues} -> {:error, {:invalid_request, issues}}
      end
    end
  end

  defp built(plan) do
    case Plan.built(plan) do
      {:ok, warnings} -> {:ok, warnings}
      {:error, issues} -> {:error, {:invalid_request, issues}}
    end
  end

  def validate(%Config{} = shared, %ImagePipe.URL{plan: plan}) do
    config = shared.options

    with {:ok, request} <- request(plan, config),
         {:ok, _policy} <- Processing.prepare(request, config, ""),
         {:ok, _watermarks} <- Execution.watermark_sources(request, config),
         {:ok, warnings} <- Plan.built(plan),
         do: {:ok, warnings ++ request.ignored}
  end

  defp render(context) do
    with {:ok, output} <- Execution.open(context) do
      try do
        with {:ok, data, type, debug} <- Output.buffer(output),
             {:ok, %Result{} = result} <-
               result(context.request.output.terminal, data, type, debug) do
          {:ok, %{result | degraded?: output.degraded?}}
        end
      after
        Execution.close_output(output)
      end
    end
  end

  defp result(:image, data, content_type, debug) do
    with {:ok, {width, height}} <- dimensions(data, debug) do
      {:ok,
       %Result{
         terminal: :image,
         data: data,
         content_type: content_type,
         format: format(content_type),
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
  defp format(content_type),
    do: Enum.find(Format.source_formats(), &(Format.mime_type!(&1) == content_type))

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
      result -> %{result: result, error: Telemetry.error_tag(reason)}
    end
  end
end

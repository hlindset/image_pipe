defmodule ImagePipe.Plan do
  @moduledoc """
  Product-neutral execution request produced by parameter parsers.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format],
    exports: [
      Pipeline,
      Output,
      Output.QualitySearch,
      Output.QualitySearch.Metric,
      Output.QualitySearch.Size,
      Output.QualitySearch.Ssimulacra2,
      Output.QualitySearch.Butteraugli,
      Output.JpegOptions,
      Output.PngOptions,
      Output.WebpOptions,
      Output.AvifOptions,
      Output.JxlOptions,
      RenderContext,
      Response,
      SourceInfo,
      Color,
      KeyData,
      Measure,
      Source,
      Source.Identity,
      Source.Path,
      Source.URL,
      Source.Object,
      Source.Reference,
      Operation,
      Operation.Background,
      Operation.Bitonal,
      Operation.Blur,
      Operation.Brightness,
      Operation.Canvas,
      Operation.Colorize,
      Operation.Contrast,
      Operation.CropGuided,
      Operation.CropRegion,
      Operation.Duotone,
      Operation.Flip,
      Operation.Gradient,
      Operation.Gray,
      Operation.Monochrome,
      Operation.Padding,
      Operation.Pixelate,
      Operation.Rotate,
      Operation.Resize,
      Operation.Saturation,
      Operation.Sharpen,
      Operation.Trim
    ]

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  @enforce_keys [:source, :pipelines, :output]
  defstruct @enforce_keys ++
              [
                expires: 0,
                cachebuster: nil,
                response: %Response{},
                auto_rotate: false,
                render: :image
              ]

  @type t :: %__MODULE__{
          source: ImagePipe.Plan.Source.t(),
          pipelines: [ImagePipe.Plan.Pipeline.t()],
          output: ImagePipe.Plan.Output.t() | nil,
          expires: non_neg_integer(),
          cachebuster: String.t() | nil,
          response: Response.t(),
          auto_rotate: boolean(),
          render: :image | {:custom, module(), map()}
        }

  @type pipeline_error() ::
          :empty_pipeline_plan
          | {:invalid_pipeline_plan, term()}
          | {:invalid_pipeline_operation, term()}

  @type shape_error() ::
          {:unsupported_source, term()}
          | {:invalid_output_plan, term()}
          | {:invalid_expires, term()}
          | {:invalid_cachebuster, term()}
          | {:invalid_response_plan, term()}
          | {:invalid_auto_rotate, term()}
          | {:invalid_render_plan, term()}

  @spec validate_shape(t()) :: {:ok, t()} | {:error, shape_error()}
  def validate_shape(%__MODULE__{} = plan) do
    with :ok <- validate_source(plan.source),
         :ok <- validate_terminal(plan.render, plan.output),
         :ok <- validate_expires(plan.expires),
         :ok <- validate_cachebuster(plan.cachebuster),
         :ok <- validate_response(plan.response),
         :ok <- validate_auto_rotate(plan.auto_rotate) do
      {:ok, plan}
    end
  end

  @doc "Returns the detect-guide classes if any operation requests detection, else nil."
  @spec detect_classes(t()) :: :all | nonempty_list(String.t()) | nil
  def detect_classes(%__MODULE__{pipelines: pipelines}) do
    pipelines
    |> Enum.flat_map(& &1.operations)
    |> Enum.reduce_while([], fn op, acc ->
      case Map.get(op, :guide) do
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {classes, _weights}} when is_list(classes) -> {:cont, classes ++ acc}
        _ -> {:cont, acc}
      end
    end)
    |> case do
      :all -> :all
      [] -> nil
      classes -> classes |> Enum.uniq() |> Enum.sort()
    end
  end

  @doc "Returns true if any operation requests a face-assisted smart guide."
  @spec face_assist?(t()) :: boolean()
  def face_assist?(%__MODULE__{pipelines: pipelines}) do
    Enum.any?(pipelines, fn p ->
      Enum.any?(p.operations, &(Map.get(&1, :guide) == {:smart, :face_assist}))
    end)
  end

  @doc """
  Ordered list of semantic operation-name atoms across all pipelines.
  Used as product-neutral aggregate metadata on the transform-execute span.
  """
  @spec operation_names(t()) :: [atom()]
  def operation_names(%__MODULE__{pipelines: pipelines}) do
    Enum.flat_map(pipelines, fn %Pipeline{operations: ops} ->
      Enum.map(ops, &Operation.name/1)
    end)
  end

  @spec validated_pipelines(t()) :: {:ok, [Pipeline.t()]} | {:error, pipeline_error()}
  def validated_pipelines(%__MODULE__{pipelines: []}), do: {:error, :empty_pipeline_plan}

  def validated_pipelines(%__MODULE__{pipelines: pipelines}) when is_list(pipelines) do
    case do_validate_pipelines(pipelines) do
      {:ok, valid_pipelines} -> {:ok, Enum.reverse(valid_pipelines)}
      {:error, _reason} = error -> error
    end
  end

  def validated_pipelines(%__MODULE__{pipelines: pipelines}),
    do: {:error, {:invalid_pipeline_plan, pipelines}}

  defp do_validate_pipelines(pipelines) do
    Enum.reduce_while(pipelines, {:ok, []}, fn
      %Pipeline{operations: operations} = pipeline, {:ok, valid_pipelines}
      when is_list(operations) ->
        case Enum.find(operations, &invalid_operation?/1) do
          nil -> {:cont, {:ok, [pipeline | valid_pipelines]}}
          operation -> {:halt, {:error, {:invalid_pipeline_operation, operation}}}
        end

      _pipeline, _acc ->
        {:halt, {:error, {:invalid_pipeline_plan, pipelines}}}
    end)
  end

  defp invalid_operation?(%_{} = operation), do: not Operation.semantic?(operation)
  defp invalid_operation?(_operation), do: true

  defp validate_source(%Source.Path{segments: segments} = source) do
    if segments != [] and valid_path_segments?(segments),
      do: :ok,
      else: {:error, {:unsupported_source, source}}
  end

  defp validate_source(%Source.URL{} = source) do
    if valid_url_source?(source),
      do: :ok,
      else: {:error, {:unsupported_source, source}}
  end

  defp validate_source(%Source.Object{} = source) do
    if valid_object_source?(source),
      do: :ok,
      else: {:error, {:unsupported_source, source}}
  end

  defp validate_source(%Source.Reference{} = source) do
    if valid_reference_source?(source),
      do: :ok,
      else: {:error, {:unsupported_source, source}}
  end

  defp validate_source(source), do: {:error, {:unsupported_source, source}}

  defp valid_path_segments?([]), do: true

  defp valid_path_segments?([segment | rest]),
    do: valid_path_segment?(segment) and valid_path_segments?(rest)

  defp valid_path_segments?(_segments), do: false

  defp valid_path_segment?(segment) when is_binary(segment) do
    segment != "" and segment != "." and segment != ".." and
      not String.contains?(segment, ["/", "\\"])
  end

  defp valid_path_segment?(_segment), do: false

  defp valid_url_source?(%Source.URL{
         scheme: scheme,
         host: host,
         port: port,
         path: path,
         query: query
       }) do
    scheme in [:http, :https] and valid_non_empty_string?(host) and valid_port?(port) and
      valid_path_segments?(path) and valid_optional_string?(query)
  end

  defp valid_object_source?(%Source.Object{
         adapter: adapter,
         scope: scope,
         key: key,
         revision: revision
       }) do
    is_atom(adapter) and valid_non_empty_string?(scope) and valid_non_empty_string?(key) and
      valid_optional_string?(revision)
  end

  defp valid_reference_source?(%Source.Reference{
         adapter: adapter,
         id: id,
         revision: revision,
         metadata: metadata
       }) do
    is_atom(adapter) and valid_non_empty_string?(id) and valid_optional_string?(revision) and
      Keyword.keyword?(metadata)
  end

  defp valid_non_empty_string?(value), do: is_binary(value) and value != ""

  defp valid_optional_string?(nil), do: true
  defp valid_optional_string?(value), do: is_binary(value)

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535

  defp validate_output(%Output{mode: :automatic} = output) do
    validate_output_quality_shape(output)
  end

  defp validate_output(%Output{mode: {:explicit, format}} = output) do
    case ImagePipe.Format.output_format?(format) do
      true -> validate_output_quality_shape(output)
      false -> {:error, {:invalid_output_plan, output}}
    end
  end

  defp validate_output(output), do: {:error, {:invalid_output_plan, output}}

  defp validate_output_quality_shape(output) do
    with :ok <- validate_output_quality(output),
         :ok <- validate_encoder_options(output) do
      :ok
    else
      :error -> {:error, {:invalid_output_plan, output}}
    end
  end

  @encoder_option_structs %{
    jpeg: Output.JpegOptions,
    png: Output.PngOptions,
    webp: Output.WebpOptions,
    avif: Output.AvifOptions,
    jpeg_xl: Output.JxlOptions
  }

  defp validate_encoder_options(%Output{encoder_options: opts}) when is_map(opts) do
    if Enum.all?(opts, fn {format, value} ->
         is_struct(value) and Map.get(@encoder_option_structs, format) == value.__struct__
       end),
       do: :ok,
       else: :error
  end

  defp validate_encoder_options(_output), do: :error

  defp validate_output_quality(%Output{quality: quality, format_qualities: format_qualities})
       when is_map(format_qualities) do
    with :ok <- validate_quality(quality),
         do: validate_format_qualities(format_qualities)
  end

  defp validate_output_quality(_output), do: :error

  defp validate_format_qualities(format_qualities) do
    if Enum.all?(format_qualities, fn {format, quality} ->
         ImagePipe.Format.output_format?(format) and valid_quality?(quality)
       end) do
      :ok
    else
      :error
    end
  end

  defp validate_quality(quality) do
    if valid_quality?(quality), do: :ok, else: :error
  end

  defp valid_quality?(:default), do: true
  defp valid_quality?({:quality, value}) when is_integer(value) and value in 1..100, do: true
  defp valid_quality?(_quality), do: false

  defp validate_expires(expires) when is_integer(expires) and expires >= 0, do: :ok

  defp validate_expires(expires), do: {:error, {:invalid_expires, expires}}

  defp validate_cachebuster(cachebuster) when is_binary(cachebuster) or is_nil(cachebuster),
    do: :ok

  defp validate_cachebuster(cachebuster), do: {:error, {:invalid_cachebuster, cachebuster}}

  defp validate_response(%Response{disposition: disposition, filename: filename} = response)
       when disposition in [:default, :inline, :attachment] do
    if is_nil(filename) or Response.valid_filename?(filename) do
      :ok
    else
      {:error, {:invalid_response_plan, response}}
    end
  end

  defp validate_response(response), do: {:error, {:invalid_response_plan, response}}

  defp validate_auto_rotate(value) when is_boolean(value), do: :ok
  defp validate_auto_rotate(value), do: {:error, {:invalid_auto_rotate, value}}

  # The terminal pairs the render selector with the output config: only the
  # built-in `:image` terminal carries an image `%Output{}`; a custom renderer
  # produces its own body and carries no image output (`nil`). Validating them
  # together keeps the two in lockstep — an `:image` plan with no output, or a
  # custom render smuggling an image output, is malformed.
  defp validate_terminal(:image, output), do: validate_output(output)

  defp validate_terminal({:custom, module, params}, nil)
       when is_atom(module) and is_map(params),
       do: :ok

  defp validate_terminal({:custom, module, params} = render, _output)
       when is_atom(module) and is_map(params),
       do: {:error, {:invalid_render_plan, render}}

  defp validate_terminal(render, _output), do: {:error, {:invalid_render_plan, render}}
end

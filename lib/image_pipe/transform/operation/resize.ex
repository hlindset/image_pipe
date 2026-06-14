defmodule ImagePipe.Transform.Operation.Resize do
  @moduledoc """
  Represents an executable resize operation whose dimension mode is known
  before execution.

  Transform Plan execution may convert semantic Plan operations to this
  executable operation after a cache miss. Parser modules should construct
  `ImagePipe.Plan.Operation.*` through Plan constructors.

  `Resize` does not perform result cropping. Transform Plan execution for
  cover-style output should include a separate crop operation after a fill-like
  resize when that matches the requested semantics.

  Enlargement: `enlarge: true` upscales; `reject_enlargement: true` errors
  (`{:error, {:bad_request, :upscale_required}}`) on a genuine upscale; both
  `false` (default) clamps to the source. They are mutually exclusive by
  convention — `ImagePipe.Transform.PlanExecutor.resize_from/2` sets at most one.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State
  import ImagePipe.Transform.Geometry

  alias ImagePipe.Transform.State

  @type pixels() :: {:pixels, non_neg_integer() | float()}
  @type dimension() :: :auto | pixels() | {:percent, number()} | {:scale, number()}
  @type mode() :: :fit | :fill | :fill_down | :force

  @type t :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          min_width: pixels() | nil,
          min_height: pixels() | nil,
          zoom_x: float(),
          zoom_y: float(),
          dpr: float(),
          enlarge: boolean(),
          reject_enlargement: boolean(),
          max_width: pos_integer() | nil,
          max_height: pos_integer() | nil,
          max_area: pos_integer() | nil
        }

  @type resolved_dimensions() :: %{
          requested_width: pos_integer() | :auto,
          requested_height: pos_integer() | :auto,
          target_width: pos_integer() | :auto,
          target_height: pos_integer() | :auto,
          result_box_width: pos_integer() | :auto,
          result_box_height: pos_integer() | :auto,
          intermediate_width: pos_integer(),
          intermediate_height: pos_integer(),
          effective_dpr: float(),
          upscale_required: boolean()
        }

  defstruct mode: :fit,
            width: :auto,
            height: :auto,
            min_width: nil,
            min_height: nil,
            zoom_x: 1.0,
            zoom_y: 1.0,
            dpr: 1.0,
            enlarge: false,
            reject_enlargement: false,
            max_width: nil,
            max_height: nil,
            max_area: nil

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :resize

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    {src_w, src_h} = State.effective_source_dims(state)

    dimensions =
      resolve_dimensions(operation,
        source_width: src_w,
        source_height: src_h
      )

    if operation.reject_enlargement and dimensions.upscale_required do
      {:error, {:bad_request, :upscale_required}}
    else
      case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
        {:ok, image} ->
          # The residual resize has finished the downscale: the image is now at its
          # final resolution, so neither the stored original extent (source_dimensions)
          # nor the realized shrink-on-load factor (decode_shrink) applies any longer.
          # Clearing decode_shrink confines the preshrink coordinate rescale to the
          # pipeline whose decode produced it, so an absolute crop in a later chained
          # pipeline is sized against that pipeline's input, not divided by a stale
          # factor (#180). See the scaleOnLoad row in docs/imgproxy_support_matrix.md.
          {:ok, %State{set_image(state, image) | source_dimensions: nil, decode_shrink: nil}}

        {:error, reason} ->
          {:error, {__MODULE__, reason}}
      end
    end
  end

  @doc false
  @spec resolve_dimensions(t(), keyword()) :: resolved_dimensions()
  def resolve_dimensions(%__MODULE__{} = operation, opts) when is_list(opts) do
    source = source_dimensions(opts)
    operation = resolve_relative_dimensions(operation, source)
    operation = normalize(operation)
    base = resolve_base_dimensions(operation, source)
    effective_dpr = effective_dpr(operation, base, source, opts)
    requested = apply_dpr(base, effective_dpr)
    min_dimensions = resolve_min_dimensions(operation, source, effective_dpr)

    target =
      target_dimensions(operation.mode, requested, min_dimensions, source, operation.enlarge)

    intermediate =
      intermediate_dimensions(
        operation.mode,
        requested,
        min_dimensions,
        source,
        operation.enlarge
      )

    result_box = result_crop_box(operation, effective_dpr)

    unclamped =
      target_dimensions(operation.mode, requested, min_dimensions, source, true)

    upscale_required =
      axis_exceeds?(unclamped.width, source.width) or
        axis_exceeds?(unclamped.height, source.height)

    %{
      requested_width: requested.width,
      requested_height: requested.height,
      target_width: target.width,
      target_height: target.height,
      result_box_width: result_box.width,
      result_box_height: result_box.height,
      intermediate_width: intermediate.width,
      intermediate_height: intermediate.height,
      effective_dpr: effective_dpr,
      upscale_required: upscale_required
    }
  end

  # The result-crop box mirrors imgproxy's TargetWidth/TargetHeight
  # (`Scale(po.Width, DprScale * ZoomWidth)`, prepare.go calcSizes): the literal
  # requested dimensions scaled by DPR and zoom, with NO min-dimension expansion
  # and NO fit-inside reduction. imgproxy's universal `cropToResult` step crops the
  # scaled image down to this box (center gravity), bounded to the image. For a
  # plain fit the scaled image already fits inside the box so the crop is a no-op;
  # under `mw`/`mh` the min-dimension upscale pushes the scaled image past the box
  # on one axis and the crop trims it back. An `:auto` axis (`po.Width == 0`) is
  # unconstrained, matching imgproxy's `MinNonZero` treatment of a zero crop side.
  defp result_crop_box(%__MODULE__{} = operation, effective_dpr) do
    %{
      width: result_box_axis(operation.width, operation.zoom_x, effective_dpr),
      height: result_box_axis(operation.height, operation.zoom_y, effective_dpr)
    }
  end

  defp result_box_axis(:auto, _zoom, _effective_dpr), do: :auto

  defp result_box_axis(value, zoom, effective_dpr),
    do: positive_round(value * zoom * effective_dpr)

  defp resize_image(%State{} = state, width, height) do
    source_width = image_width(state)
    source_height = image_height(state)

    if width == source_width and height == source_height do
      {:ok, state.image}
    else
      width_scale = width / source_width
      height_scale = height / source_height

      Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp source_dimensions(opts) do
    %{
      width: positive_round(Keyword.fetch!(opts, :source_width)),
      height: positive_round(Keyword.fetch!(opts, :source_height))
    }
  end

  defp resolve_relative_dimensions(%__MODULE__{} = operation, source) do
    %__MODULE__{
      operation
      | width: resolve_relative_dimension(operation.width, source.width),
        height: resolve_relative_dimension(operation.height, source.height),
        min_width: resolve_relative_dimension(operation.min_width, source.width),
        min_height: resolve_relative_dimension(operation.min_height, source.height)
    }
  end

  defp resolve_relative_dimension({:percent, _} = unit, length),
    do: {:pixels, max(1, to_pixels(length, unit))}

  defp resolve_relative_dimension({:scale, _} = unit, length),
    do: {:pixels, max(1, to_pixels(length, unit))}

  defp resolve_relative_dimension(other, _length), do: other

  defp normalize(%__MODULE__{} = operation) do
    %__MODULE__{
      operation
      | width: normalize_bound_dimension(operation.width),
        height: normalize_bound_dimension(operation.height),
        min_width: normalize_min_dimension(operation.min_width),
        min_height: normalize_min_dimension(operation.min_height),
        zoom_x: normalize_factor(operation.zoom_x, 1.0),
        zoom_y: normalize_factor(operation.zoom_y, 1.0),
        dpr: normalize_factor(operation.dpr, 1.0)
    }
  end

  defp normalize_bound_dimension(nil), do: :auto
  defp normalize_bound_dimension(:auto), do: :auto
  defp normalize_bound_dimension({:pixels, 0}), do: :auto
  defp normalize_bound_dimension({:pixels, value}), do: positive_round(value)

  defp normalize_min_dimension(nil), do: nil
  defp normalize_min_dimension(:auto), do: nil
  defp normalize_min_dimension({:pixels, 0}), do: nil
  defp normalize_min_dimension({:pixels, value}), do: positive_round(value)

  defp normalize_factor(nil, default), do: default
  defp normalize_factor(value, _default), do: value * 1.0

  defp resolve_base_dimensions(%__MODULE__{width: :auto, height: :auto} = operation, source) do
    if factor_requested?(operation) do
      source
      |> apply_zoom(operation)
    else
      %{width: :auto, height: :auto}
    end
  end

  defp resolve_base_dimensions(%__MODULE__{mode: :fit} = operation, source) do
    operation
    |> requested_box(source)
    |> fit_inside(source)
    |> apply_zoom(operation)
  end

  defp resolve_base_dimensions(%__MODULE__{mode: mode} = operation, source)
       when mode in [:fill, :fill_down, :force] do
    operation
    |> requested_box(source)
    |> apply_zoom(operation)
  end

  defp requested_box(%__MODULE__{mode: :force, width: :auto, height: height}, source) do
    %{width: source.width, height: height}
  end

  defp requested_box(%__MODULE__{mode: :force, width: width, height: :auto}, source) do
    %{width: width, height: source.height}
  end

  defp requested_box(%__MODULE__{width: :auto, height: height}, source) do
    %{width: height * source.width / source.height, height: height}
  end

  defp requested_box(%__MODULE__{width: width, height: :auto}, source) do
    %{width: width, height: width * source.height / source.width}
  end

  defp requested_box(%__MODULE__{width: width, height: height}, _source) do
    %{width: width, height: height}
  end

  defp fit_inside(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: width, height: width / source_ratio}
    else
      %{width: height * source_ratio, height: height}
    end
  end

  defp apply_zoom(%{width: width, height: height}, %__MODULE__{zoom_x: zoom_x, zoom_y: zoom_y}) do
    %{width: width * zoom_x, height: height * zoom_y}
  end

  defp effective_dpr(%__MODULE__{enlarge: true, dpr: dpr}, _base, _source, _opts), do: dpr
  defp effective_dpr(%__MODULE__{dpr: 1.0}, _base, _source, _opts), do: 1.0

  defp effective_dpr(%__MODULE__{dpr: dpr}, %{width: :auto, height: :auto}, _source, _opts),
    do: dpr

  defp effective_dpr(%__MODULE__{dpr: dpr}, base, source, _opts) do
    max_dpr = min(source.width / base.width, source.height / base.height)
    min(dpr, max_dpr)
  end

  defp apply_dpr(%{width: :auto, height: :auto}, _effective_dpr),
    do: %{width: :auto, height: :auto}

  defp apply_dpr(%{width: width, height: height}, effective_dpr) do
    %{
      width: positive_round(width * effective_dpr),
      height: positive_round(height * effective_dpr)
    }
  end

  defp resolve_min_dimensions(
         %__MODULE__{min_width: nil, min_height: nil},
         _source,
         _effective_dpr
       ),
       do: nil

  defp resolve_min_dimensions(%__MODULE__{} = operation, source, effective_dpr) do
    width = scaled_min(operation.min_width, effective_dpr)
    height = scaled_min(operation.min_height, effective_dpr)

    requested_box(%__MODULE__{operation | width: width || :auto, height: height || :auto}, source)
  end

  defp scaled_min(nil, _effective_dpr), do: nil
  defp scaled_min(value, effective_dpr), do: positive_round(value * effective_dpr)

  defp factor_requested?(%__MODULE__{} = operation) do
    operation.zoom_x != 1.0 or operation.zoom_y != 1.0 or operation.dpr != 1.0
  end

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, nil, _source, _enlarge),
    do: %{width: :auto, height: :auto}

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, min_dimensions, source, _enlarge) do
    target_box_dimensions(source, min_dimensions)
  end

  defp target_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp intermediate_dimensions(_mode, %{width: :auto, height: :auto}, nil, source, _enlarge),
    do: source

  defp intermediate_dimensions(
         _mode,
         %{width: :auto, height: :auto},
         min_dimensions,
         source,
         _enlarge
       ) do
    target_box_dimensions(source, min_dimensions)
  end

  defp intermediate_dimensions(:fill, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(_mode, requested, nil, source, enlarge) do
    clamp_to_source(requested, source, enlarge)
  end

  defp intermediate_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_box_dimensions(requested, nil), do: requested

  defp target_box_dimensions(requested, min_dimensions) do
    width_scale = min_dimensions.width / requested.width
    height_scale = min_dimensions.height / requested.height
    scale = max(1.0, max(width_scale, height_scale))

    scale_dimensions(requested, scale)
  end

  defp cover_resize_dimensions(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: positive_round(height * source_ratio), height: height}
    else
      %{width: width, height: positive_round(width / source_ratio)}
    end
  end

  defp scale_dimensions(%{width: width, height: height}, scale) do
    %{width: positive_round(width * scale), height: positive_round(height * scale)}
  end

  defp clamp_to_source(dimensions, _source, true), do: dimensions

  defp clamp_to_source(%{width: width, height: height} = dimensions, source, false) do
    scale = min(1.0, min(source.width / width, source.height / height))

    if scale < 1.0 do
      scale_dimensions(dimensions, scale)
    else
      dimensions
    end
  end

  defp positive_round(value) when is_number(value) do
    value
    |> round()
    |> max(1)
  end

  defp axis_exceeds?(:auto, _source), do: false
  defp axis_exceeds?(value, source) when is_integer(value), do: value > source
end

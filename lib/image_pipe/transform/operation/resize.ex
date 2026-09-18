defmodule ImagePipe.Transform.Operation.Resize do
  @moduledoc """
  Represents an executable resize operation whose dimension mode is known
  before execution. The native executor constructs this operation after it
  resolves request geometry.

  `Resize` does not perform result cropping. Cover-style execution includes a
  separate crop operation after a fill-like resize.

  `enlarge: true` permits upscaling; `false` clamps to the source.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.Geometry, only: [image_height: 1, image_width: 1]
  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @type pixels() :: {:pixels, pos_integer() | float()}
  @type dimension() :: :auto | pixels()
  @type zoom() :: float()
  @type mode() :: :fit | :fill | :fill_down | :force

  @type t :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          min_width: pixels() | nil,
          min_height: pixels() | nil,
          zoom_x: zoom(),
          zoom_y: zoom(),
          dpr: float(),
          enlarge: boolean()
        }

  @type resolved_dimensions() :: %{
          intermediate_width: pos_integer(),
          intermediate_height: pos_integer()
        }

  defstruct mode: :fit,
            width: :auto,
            height: :auto,
            min_width: nil,
            min_height: nil,
            zoom_x: 1.0,
            zoom_y: 1.0,
            dpr: 1.0,
            enlarge: false

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

    case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
      {:ok, image} ->
        # The residual resize has finished the downscale: the image is now at its
        # final resolution, so neither the stored original extent (source_dimensions)
        # nor the realized shrink-on-load factor (decode_shrink) applies any longer.
        # Clearing decode_shrink confines the preshrink coordinate rescale to the
        # pipeline whose decode produced it, so an absolute crop in a later chained
        # pipeline is sized against that pipeline's input, not divided by a stale
        # factor.
        state = set_image(state, image)
        {:ok, %State{state | source_dimensions: nil, decode_shrink: nil}}

      {:error, reason} ->
        {:error, {__MODULE__, reason}}
    end
  end

  @doc false
  @spec resolve_dimensions(t(), keyword()) :: resolved_dimensions()
  def resolve_dimensions(%__MODULE__{} = operation, opts) when is_list(opts) do
    source = source_dimensions(opts)
    operation = normalize(operation)
    base = resolve_base_dimensions(operation, source)
    effective_dpr = effective_dpr(operation, base, source, opts)
    requested = apply_dpr(base, effective_dpr)
    min_dimensions = resolve_min_dimensions(operation, source, effective_dpr)

    intermediate =
      intermediate_dimensions(
        operation.mode,
        requested,
        min_dimensions,
        source,
        operation.enlarge
      )

    %{
      intermediate_width: intermediate.width,
      intermediate_height: intermediate.height
    }
  end

  @doc false
  @spec native_target(t(), keyword()) :: %{
          width: pos_integer(),
          height: pos_integer(),
          dpr: float()
        }
  def native_target(%__MODULE__{} = operation, opts) do
    source = source_dimensions(opts)
    operation = normalize(operation)
    base = native_base(operation, source)
    base = native_minimum(base, operation)
    dpr = native_dpr(operation, base, source)
    %{width: width, height: height} = apply_dpr(base, dpr)
    %{width: width, height: height, dpr: dpr}
  end

  defp native_base(%__MODULE__{mode: :fit, width: :auto, height: :auto} = operation, source),
    do: source |> apply_zoom(operation) |> fit_inside(source)

  defp native_base(%__MODULE__{width: :auto, height: :auto} = operation, source),
    do: apply_zoom(source, operation)

  defp native_base(%__MODULE__{mode: :fit} = operation, source) do
    operation |> native_box(source) |> fit_inside(source)
  end

  defp native_base(%__MODULE__{} = operation, source),
    do: native_box(operation, source)

  defp native_box(operation, source) do
    %{
      operation
      | width: native_zoom_axis(operation.width, operation.zoom_x),
        height: native_zoom_axis(operation.height, operation.zoom_y)
    }
    |> requested_box(source)
  end

  defp native_zoom_axis(:auto, _zoom), do: :auto
  defp native_zoom_axis(value, zoom), do: zoom_axis(value, zoom)

  defp native_minimum(base, operation) do
    scale =
      max(
        minimum_scale(operation.min_width, base.width),
        minimum_scale(operation.min_height, base.height)
      )

    %{width: base.width * scale, height: base.height * scale}
  end

  defp minimum_scale(nil, _base), do: 1.0
  defp minimum_scale(minimum, base), do: max(1.0, minimum / base)

  defp native_dpr(%__MODULE__{enlarge: true, mode: mode, dpr: dpr}, _base, _source)
       when mode != :fill_down,
       do: dpr

  defp native_dpr(%__MODULE__{dpr: dpr}, base, source),
    do: min(dpr, min(source.width / base.width, source.height / base.height))

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

  defp normalize_bound_dimension(:auto), do: :auto
  defp normalize_bound_dimension({:pixels, value}), do: positive_round(value)

  defp normalize_min_dimension(nil), do: nil
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
    %{width: zoom_axis(width, zoom_x), height: zoom_axis(height, zoom_y)}
  end

  defp zoom_axis(length, factor), do: length * factor

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
    not unit_zoom?(operation.zoom_x) or not unit_zoom?(operation.zoom_y) or operation.dpr != 1.0
  end

  defp unit_zoom?(value), do: value == 1.0

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
end

defmodule ImagePipe.Transform.Operation.ExtendCanvas do
  @moduledoc """
  Represents an executable canvas expansion operation that embeds the
  current image into a same-size-or-larger canvas.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation. Parser modules should construct
  `ImagePipe.Plan.Operation.*` through Plan constructors.

  Use it for resolved letterboxing, padding, or aspect-ratio canvas extension
  without changing the image content scale.

  ## Fields

  Required fields:

  - `rule`: either `{:dimensions, width, height}` or
    `{:aspect_ratio, {ratio_width, ratio_height}}`.

  Optional fields:

  - `gravity`: an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`. Defaults
    to center.
  - `x_offset`: numeric horizontal offset added after gravity placement.
    Defaults to `0.0`.
  - `y_offset`: numeric vertical offset added after gravity placement. Defaults
    to `0.0`.
  - `background`: background fill passed to `Image.embed/4`. Defaults to
    `:white`; `:transparent` is converted to an RGBA transparent color.

  Dimension rules accept non-negative numbers, `{:pixels, value}` with a
  non-negative value, or `:auto` on each axis. Aspect-ratio rules require
  positive numeric ratio components.

  ## Execution Semantics

  `execute/2` resolves the canvas size from `rule`, embeds
  `ImagePipe.Transform.State.image` into that canvas, and stores the embedded
  image back into the state. If dimensions are invalid or embedding fails,
  execution returns `{:error, {__MODULE__, reason}}`.

  For `{:dimensions, width, height}`, each requested dimension resolves against
  the current image size. `:auto` keeps the current size on that axis. The final
  canvas width and height are never smaller than the current image.

  For `{:aspect_ratio, {ratio_width, ratio_height}}`, execution expands the
  canvas on the needed axis so the final canvas has the requested ratio while
  preserving the full current image. The image is not resampled by this
  operation.

  Gravity chooses the base image placement in the new canvas. Offsets are
  rounded and added to that placement after gravity resolution, then passed to
  image embedding.

  ## Examples

      canvas = %ImagePipe.Transform.Operation.ExtendCanvas{
        rule: {:dimensions, {:pixels, 400}, {:pixels, 300}},
        gravity: {:anchor, :center, :center},
        x_offset: 0.0,
        y_offset: 0.0
      }

  A semantic canvas request for extend-aspect-ratio may execute as an
  `ExtendCanvas` operation with an `{:aspect_ratio, ratio}` rule.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  import ImagePipe.Transform.Geometry,
    only: [
      center_origin: 2,
      image_height: 1,
      image_width: 1,
      resolve_dimension: 2
    ]

  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.State

  @default_gravity {:anchor, :center, :center}

  defstruct rule: nil,
            gravity: @default_gravity,
            x_offset: 0.0,
            y_offset: 0.0,
            background: :white

  @type scalar() :: non_neg_integer() | float()
  @type length() :: scalar() | {:pixels, scalar()}
  @type ratio() :: {pos_integer() | float(), pos_integer() | float()}

  @type canvas_rule() ::
          {:dimensions, length() | :auto, length() | :auto}
          | {:aspect_ratio, ratio()}

  @type t :: %__MODULE__{
          rule: canvas_rule(),
          gravity: {:anchor, :left | :center | :right, :top | :center | :bottom},
          x_offset: number(),
          y_offset: number(),
          background: term()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :extend_canvas

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    with {:ok, {width, height}} <- canvas_dimensions(state, operation.rule),
         false <- inert_extend?(state, width, height),
         {:ok, {image, x, y}} <- embed_image(state, operation, width, height) do
      # The canvas embed places the image content at (x, y) in the larger frame, so
      # a carried focus translates by the realized embed offset onto its content.
      {:ok, set_image(Focus.translate(state, x, y), image)}
    else
      true -> {:ok, state}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  # imgproxy extendImage() returns early when the canvas doesn't grow on either
  # axis (`width <= imgWidth && height <= imgHeight`), leaving the image
  # untouched. canvas_dimensions/2 already clamps to max(image, requested), so an
  # inert extend yields canvas dims == image dims; skip the embed so no alpha
  # channel is introduced.
  defp inert_extend?(%State{} = state, width, height) do
    width == image_width(state) and height == image_height(state)
  end

  defp canvas_dimensions(%State{} = state, {:dimensions, width, height}) do
    width = canvas_dimension(image_width(state), width)
    height = canvas_dimension(image_height(state), height)

    {:ok, {max(image_width(state), width), max(image_height(state), height)}}
  end

  defp canvas_dimensions(%State{} = state, {:aspect_ratio, {ratio_width, ratio_height}})
       when is_number(ratio_width) and is_number(ratio_height) and ratio_width > 0 and
              ratio_height > 0 do
    target_ratio = ratio_width / ratio_height
    source_ratio = image_width(state) / image_height(state)

    {width, height} =
      if source_ratio > target_ratio do
        {image_width(state), round(image_width(state) / target_ratio)}
      else
        {round(image_height(state) * target_ratio), image_height(state)}
      end

    {:ok, {max(image_width(state), width), max(image_height(state), height)}}
  end

  defp canvas_dimensions(_state, rule), do: {:error, {:invalid_canvas_rule, rule}}

  defp embed_image(%State{} = state, %__MODULE__{} = operation, width, height) do
    x = offset(:x, operation.gravity, operation.x_offset, image_width(state), width)
    y = offset(:y, operation.gravity, operation.y_offset, image_height(state), height)

    with {:ok, image} <- alpha_ready_image(state.image, operation.background),
         {:ok, embedded} <-
           Image.embed(image, width, height, %{
             x: x,
             y: y,
             background_color: background_color(operation.background, image),
             extend_mode: :VIPS_EXTEND_BACKGROUND
           }) do
      {:ok, {embedded, x, y}}
    end
  end

  # imgproxy calc_position.go places the image relative to the anchored edge and
  # clamps the origin to [0, outer - inner] (allowOverflow=false). West/north/center
  # add the offset; right/bottom anchors move the image AWAY from that edge, i.e.
  # subtract (`left = outer - inner - offX`).
  defp offset(axis, gravity, configured_offset, image_size, canvas_size) do
    base = base_offset(axis, gravity, image_size, canvas_size)
    signed = base + offset_direction(axis, gravity) * round(configured_offset)

    signed
    |> max(0)
    |> min(canvas_size - image_size)
  end

  defp offset_direction(:x, {:anchor, :right, _y}), do: -1
  defp offset_direction(:y, {:anchor, _x, :bottom}), do: -1
  defp offset_direction(_axis, _gravity), do: 1

  defp base_offset(:x, {:anchor, :left, _y}, _image_size, _canvas_size), do: 0

  defp base_offset(:x, {:anchor, :center, _y}, image_size, canvas_size),
    do: center_origin(canvas_size, image_size)

  defp base_offset(:x, {:anchor, :right, _y}, image_size, canvas_size),
    do: canvas_size - image_size

  defp base_offset(:y, {:anchor, _x, :top}, _image_size, _canvas_size), do: 0

  defp base_offset(:y, {:anchor, _x, :center}, image_size, canvas_size),
    do: center_origin(canvas_size, image_size)

  defp base_offset(:y, {:anchor, _x, :bottom}, image_size, canvas_size),
    do: canvas_size - image_size

  defp canvas_dimension(current_size, :auto), do: current_size

  defp canvas_dimension(_current_size, {:pixels, value}) when is_number(value) and value >= 0,
    do: round(value)

  defp canvas_dimension(_current_size, value) when is_number(value) and value >= 0,
    do: round(value)

  defp canvas_dimension(current_size, size_unit),
    do: resolve_dimension(size_unit, current_size)

  defp alpha_ready_image(image, :transparent) do
    case Image.has_alpha?(image) do
      true -> {:ok, image}
      false -> Image.add_alpha(image, :opaque)
    end
  end

  defp alpha_ready_image(image, {:color, [_red, _green, _blue, _alpha]}) do
    case Image.has_alpha?(image) do
      true -> {:ok, image}
      false -> Image.add_alpha(image, :opaque)
    end
  end

  defp alpha_ready_image(image, _background), do: {:ok, image}

  defp background_color(:transparent, _image), do: [0, 0, 0, 0]
  defp background_color(:white, image), do: alpha_aware_color([255, 255, 255], image)
  defp background_color(:black, image), do: alpha_aware_color([0, 0, 0], image)
  defp background_color({:color, color}, image), do: alpha_aware_color(color, image)
  defp background_color(color, _image), do: color

  defp alpha_aware_color([_red, _green, _blue, _alpha] = color, _image), do: color

  defp alpha_aware_color(color, image) do
    case Image.has_alpha?(image) do
      true -> color ++ [255]
      false -> color
    end
  end
end

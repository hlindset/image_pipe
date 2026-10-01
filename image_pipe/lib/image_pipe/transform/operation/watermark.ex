defmodule ImagePipe.Transform.Operation.Watermark do
  @moduledoc """
  Composites a watermark asset over the image.

  The executor prepares `image` in the frame's color space and resolves every
  length to pixels before constructing this operation.

  ## Fields

  - `image`: the asset, with an alpha band, in display orientation.
  - `width`, `height`: the drawn asset size in pixels, at least 1.
  - `opacity`: from 0 (exclusive) to 1, multiplying the asset alpha.
  - `gravity`: `{:anchor, :left | :center | :right, :top | :center | :bottom}`.
  - `x_offset`, `y_offset`: integer pixels moving the asset inward from
    right/bottom anchors and forward from left/top/center anchors.
  - `tile`: repeat the asset across the frame.
  - `gap`: `{x, y}` non-negative integer pixels between tiles.

  ## Execution Semantics

  Placement is not clamped: an asset partly outside the frame is clipped, and
  one entirely outside leaves the image unchanged. A tiled asset repeats in
  every direction from its anchored position. The asset composites `over` the
  image; an image without alpha keeps none, and the result retains the image's
  band format.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State
  import ImagePipe.Transform.Geometry, only: [center_origin: 2]

  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [
    :image,
    :width,
    :height,
    :opacity,
    :gravity,
    :x_offset,
    :y_offset,
    :tile,
    :gap
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          image: VipsImage.t(),
          width: pos_integer(),
          height: pos_integer(),
          opacity: float(),
          gravity: {:anchor, :left | :center | :right, :top | :center | :bottom},
          x_offset: integer(),
          y_offset: integer(),
          tile: boolean(),
          gap: {non_neg_integer(), non_neg_integer()}
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :watermark

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    with {:ok, mark} <- size(operation.image, operation.width, operation.height),
         {:ok, mark} <- fade(mark, operation.opacity),
         {:ok, image} <- place(state.image, mark, operation) do
      {:ok, set_image(state, image)}
    else
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  defp size(image, width, height) do
    case {VipsImage.width(image), VipsImage.height(image)} do
      {^width, ^height} ->
        {:ok, image}

      {current_width, current_height} ->
        AlphaPremultiply.with_alpha_premultiplied(image, fn premultiplied ->
          Operation.resize(premultiplied, width / current_width, vscale: height / current_height)
        end)
    end
  end

  defp fade(image, opacity) when opacity == 1.0, do: {:ok, image}

  defp fade(image, opacity) do
    color_bands = VipsImage.bands(image) - 1

    with {:ok, faded} <-
           Operation.linear(
             image,
             List.duplicate(1.0, color_bands) ++ [opacity],
             List.duplicate(0.0, color_bands + 1)
           ) do
      Operation.cast(faded, VipsImage.format(image))
    end
  end

  defp place(base, mark, operation) do
    frame = {VipsImage.width(base), VipsImage.height(base)}
    size = {VipsImage.width(mark), VipsImage.height(mark)}
    {x, y} = origin(operation, frame, size)

    cond do
      operation.tile -> tiled(base, mark, {x, y}, frame, operation.gap)
      outside?({x, y}, frame, size) -> {:ok, base}
      true -> composite(base, mark, x, y)
    end
  end

  defp outside?({x, y}, {frame_width, frame_height}, {width, height}),
    do: x >= frame_width or y >= frame_height or x + width <= 0 or y + height <= 0

  defp origin(operation, {frame_width, frame_height}, {width, height}) do
    {:anchor, x_anchor, y_anchor} = operation.gravity

    {axis_origin(x_anchor, frame_width, width, operation.x_offset),
     axis_origin(y_anchor, frame_height, height, operation.y_offset)}
  end

  defp axis_origin(anchor, _frame, _size, offset) when anchor in [:left, :top], do: offset

  defp axis_origin(:center, frame, size, offset), do: center_origin(frame, size) + offset

  defp axis_origin(anchor, frame, size, offset) when anchor in [:right, :bottom],
    do: frame - size - offset

  # One tile sits at the anchored origin; the grid repeats in every direction.
  defp tiled(base, mark, {x, y}, {frame_width, frame_height}, {gap_x, gap_y}) do
    cell_width = VipsImage.width(mark) + gap_x
    cell_height = VipsImage.height(mark) + gap_y
    start_x = grid_start(x, cell_width)
    start_y = grid_start(y, cell_height)
    across = ceil_div(frame_width - start_x, cell_width)
    down = ceil_div(frame_height - start_y, cell_height)

    with {:ok, cell} <-
           Operation.embed(mark, 0, 0, cell_width, cell_height,
             extend: :VIPS_EXTEND_BACKGROUND,
             background: List.duplicate(0.0, VipsImage.bands(mark))
           ),
         {:ok, plane} <- Operation.replicate(cell, across, down),
         {:ok, plane} <-
           Operation.extract_area(plane, -start_x, -start_y, frame_width, frame_height) do
      composite(base, plane, 0, 0)
    end
  end

  defp grid_start(origin, cell) do
    case Integer.mod(origin, cell) do
      0 -> 0
      remainder -> remainder - cell
    end
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  defp composite(base, mark, x, y) do
    alpha? = Image.has_alpha?(base)

    with {:ok, composited} <-
           Operation.composite2(base, mark, :VIPS_BLEND_MODE_OVER,
             x: x,
             y: y,
             "compositing-space": VipsImage.interpretation(base)
           ),
         {:ok, composited} <- restore_alpha(composited, alpha?) do
      Operation.cast(composited, VipsImage.format(base))
    end
  end

  defp restore_alpha(image, true), do: {:ok, image}

  defp restore_alpha(image, false),
    do: Operation.extract_band(image, 0, n: VipsImage.bands(image) - 1)
end

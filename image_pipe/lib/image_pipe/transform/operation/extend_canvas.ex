defmodule ImagePipe.Transform.Operation.ExtendCanvas do
  # Embeds the image into a same-size-or-larger transparent canvas without resampling.
  #
  # The executor resolves the canvas size for letterboxing, padding, or
  # aspect-ratio extension, at least the current image size on each axis.
  #
  # Gravity (`{:anchor, :left | :center | :right, :top | :center | :bottom}`,
  # center by default) sets the base placement. Rounded positive offsets move
  # right/down from left/top/center anchors and inward from right/bottom anchors.
  # The final origin is clamped to keep the image inside the canvas. A canvas the
  # size of the image is inert and adds no alpha band.
  @moduledoc false

  import ImagePipe.Transform.State

  import ImagePipe.Transform.Geometry,
    only: [
      center_origin: 2,
      image_height: 1,
      image_width: 1
    ]

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkLimits

  @enforce_keys [:width, :height]
  defstruct width: nil,
            height: nil,
            gravity: {:anchor, :center, :center},
            x_offset: 0.0,
            y_offset: 0.0

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          gravity: {:anchor, :left | :center | :right, :top | :center | :bottom},
          x_offset: number(),
          y_offset: number()
        }

  # Dialyzer narrows `embed_image`'s return (via the Vix `embed` typing below) and
  # then reports the `{:ok, _}` clause of this `with` as unmatchable.
  @dialyzer {:no_match, execute: 2}
  def execute(%__MODULE__{width: width, height: height} = operation, %State{} = state) do
    with :ok <- WorkLimits.embed(width, height),
         false <- inert_extend?(state, width, height),
         {:ok, image} <- embed_image(state, operation, width, height) do
      {:ok, set_image(state, image)}
    else
      true -> {:ok, state}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  # Skip unchanged canvas dimensions so an inert extension adds no alpha channel.
  defp inert_extend?(%State{} = state, width, height) do
    width == image_width(state) and height == image_height(state)
  end

  defp resolved_embed_offset(
         %__MODULE__{} = operation,
         image_width,
         image_height,
         canvas_width,
         canvas_height
       ) do
    {offset(:x, operation.gravity, operation.x_offset, image_width, canvas_width),
     offset(:y, operation.gravity, operation.y_offset, image_height, canvas_height)}
  end

  # Dialyzer can't see through Vix's generated Operation typings (embed).
  @dialyzer {:no_fail_call, embed_image: 4}
  defp embed_image(%State{} = state, %__MODULE__{} = operation, width, height) do
    {x, y} =
      resolved_embed_offset(operation, image_width(state), image_height(state), width, height)

    with {:ok, image} <- Alpha.ensure(state.image) do
      Image.embed(image, width, height, x: x, y: y, background: [0, 0, 0, 0])
    end
  end

  # Apply the anchor's offset direction, then clamp to keep the image in bounds.
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
end

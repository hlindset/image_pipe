defmodule ImagePipe.Transform.Operation.ExtendCanvas do
  @moduledoc """
  Embeds the image into a same-size-or-larger canvas without resampling.

  The executor resolves dimensions for letterboxing, padding, or
  aspect-ratio extension before constructing this operation.

  ## Fields

  Required fields:

  - `rule`: either `{:dimensions, width, height}` or
    `{:aspect_ratio, {ratio_width, ratio_height}}`.

  Optional fields:

  - `gravity`: an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`. Defaults
    to center.
  - `x_offset`: numeric horizontal offset applied after gravity placement.
    Defaults to `0.0`.
  - `y_offset`: numeric vertical offset applied after gravity placement. Defaults
    to `0.0`.
  - `background`: background fill passed to `Image.embed/4`. Defaults to
    `:white`; `:transparent` is converted to an RGBA transparent color.

  Dimension rules accept non-negative pixel numbers. Aspect-ratio rules use
  positive numeric ratio components.

  ## Execution Semantics

  `execute/2` returns state containing the embedded image, or
  `{:error, {__MODULE__, reason}}` if embedding fails.

  Dimension rules round each size and clamp it to at least the current image size.
  Aspect-ratio rules expand the needed axis, preserving the full image.

  Gravity sets the base placement. Rounded positive offsets move right/down from
  left/top/center anchors and inward from right/bottom anchors.
  The final origin is clamped to keep the image inside the canvas.

  ## Examples

      canvas = %ImagePipe.Transform.Operation.ExtendCanvas{
        rule: {:dimensions, 400, 300},
        gravity: {:anchor, :center, :center},
        x_offset: 0.0,
        y_offset: 0.0
      }
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  import ImagePipe.Transform.Geometry,
    only: [
      center_origin: 2,
      image_height: 1,
      image_width: 1
    ]

  alias ImagePipe.Transform.State

  @default_gravity {:anchor, :center, :center}

  defstruct rule: nil,
            gravity: @default_gravity,
            x_offset: 0.0,
            y_offset: 0.0,
            background: :white

  @type scalar() :: non_neg_integer() | float()
  @type ratio() :: {pos_integer() | float(), pos_integer() | float()}

  @type canvas_rule() ::
          {:dimensions, scalar(), scalar()}
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
  # Dialyzer narrows `embed_image`'s return (via the Vix `embed` typing below) and
  # then reports the `{:ok, _}` clause of this `with` as unmatchable.
  @dialyzer {:no_match, execute: 2}
  def execute(%__MODULE__{} = operation, %State{} = state) do
    with {:ok, {width, height}} <- canvas_dimensions(state, operation.rule),
         false <- inert_extend?(state, width, height),
         {:ok, {image, _x, _y}} <- embed_image(state, operation, width, height) do
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

  defp canvas_dimensions(%State{} = state, rule),
    do: resolved_canvas_dims(rule, image_width(state), image_height(state))

  @doc false
  # Pure canvas dimensions shared by execution and geometry planning.
  # Each axis is at least the image size.
  @spec resolved_canvas_dims(canvas_rule(), pos_integer(), pos_integer()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  def resolved_canvas_dims({:dimensions, width, height}, image_width, image_height) do
    {:ok, {max(image_width, round(width)), max(image_height, round(height))}}
  end

  def resolved_canvas_dims(
        {:aspect_ratio, {ratio_width, ratio_height}},
        image_width,
        image_height
      ) do
    target_ratio = ratio_width / ratio_height
    source_ratio = image_width / image_height

    {width, height} =
      if source_ratio > target_ratio do
        {image_width, round(image_width / target_ratio)}
      else
        {round(image_height * target_ratio), image_height}
      end

    {:ok, {max(image_width, width), max(image_height, height)}}
  end

  @doc false
  # Pure embed origin shared by execution and geometry planning: gravity plus
  # signed offsets, clamped inside the canvas.
  @spec resolved_embed_offset(t(), pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def resolved_embed_offset(
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

    with {:ok, image} <- alpha_ready_image(state.image, operation.background),
         {:ok, embedded} <-
           Image.embed(image, width, height,
             x: x,
             y: y,
             background: background_color(operation.background, image)
           ) do
      {:ok, {embedded, x, y}}
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

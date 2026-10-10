defmodule ImagePipe.Transform.Operation.Trim do
  # Executable uniform-border trim. Replicates imgproxy `vips_trim`
  # (`vips/vips.c`): prepare a detection copy (sRGB convert; magenta-flatten alpha),
  # resolve the background (top-left pixel for `:auto`, else the explicit color),
  # `find_trim`, symmetrize via `equal_hor`/`equal_ver`, return unchanged on a
  # degenerate box, and extract from the original image.
  @moduledoc false

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Plan.Color
  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.WorkingColor
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  # The box is found on a copy shrunk by this factor, then each edge again at
  # full resolution, on frames of at least @min_preview_pixels with both sides
  # at least @min_preview_side. Each find_trim has a fixed cost of 1-2 ms, so
  # the five searches only beat one full search on larger frames: with
  # libvips' default of one thread per core, from about a megapixel.
  @preview_shrink 8
  @min_preview_side 256
  @min_preview_pixels 1_000_000
  # Full-resolution strips reach this far past the preview's edge.
  @strip_margin 3 * @preview_shrink

  # Integers, NOT floats: flatten treats a float list as sRGB 0.0..1.0 and
  # rejects 255.0 as an out-of-range component. Integer 0..255 is accepted.
  @magenta [255, 0, 255]

  @enforce_keys [:threshold, :background, :equal_hor, :equal_ver]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          threshold: float(),
          background: :auto | Color.t(),
          equal_hor: boolean(),
          equal_ver: boolean()
        }

  def execute(%__MODULE__{} = op, %State{} = state) do
    original = state.image
    orig_w = Image.width(original)
    orig_h = Image.height(original)

    # libvips' find_trim runs a 3×3 median, which fails on an image narrower or
    # shorter than 3 pixels; such an image has nothing to trim.
    if orig_w < 3 or orig_h < 3,
      do: {:ok, state},
      else: trim(op, state, original, orig_w, orig_h)
  end

  defp trim(op, state, original, orig_w, orig_h) do
    with {:ok, prepared} <- prepare(original),
         {:ok, background} <- background_list(op.background, prepared),
         {:ok, {left, top, width, height}} <- find_box(prepared, background, op.threshold),
         {left, width} = equalize(op.equal_hor, left, width, orig_w),
         {top, height} = equalize(op.equal_ver, top, height, orig_h),
         {:ok, result} <- crop_or_passthrough(original, state, left, top, width, height) do
      {:ok, result}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # A full-resolution search reads every pixel. A preview finds each edge
  # roughly, then a full-resolution strip from the image's border to just past
  # that edge finds it exactly. The preview's median filter can erase a thin
  # mark in the border, but the strip still reaches it, so the box matches a
  # full-resolution search. When a strip's edge isn't clear of its cut, the
  # whole image is searched instead.
  defp find_box(image, background, threshold) do
    width = Image.width(image)
    height = Image.height(image)

    if min(width, height) < @min_preview_side or width * height < @min_preview_pixels do
      find_trim(image, background, threshold)
    else
      with {:ok, preview} <- Operation.shrink(image, @preview_shrink * 1.0, @preview_shrink * 1.0),
           {:ok, rough} <- find_trim(preview, background, threshold) do
        refine(image, rough, background, threshold)
      end
    end
  end

  defp refine(image, {_left, _top, width, height}, background, threshold)
       when width == 0 or height == 0,
       do: find_trim(image, background, threshold)

  defp refine(image, {left, top, width, height}, background, threshold) do
    image_width = Image.width(image)
    image_height = Image.height(image)
    near_x = min(image_width, (left + 1) * @preview_shrink + @strip_margin)
    near_y = min(image_height, (top + 1) * @preview_shrink + @strip_margin)
    far_x = max(0, (left + width - 1) * @preview_shrink - @strip_margin)
    far_y = max(0, (top + height - 1) * @preview_shrink - @strip_margin)

    with {:ok, left} <- near_edge(image, {0, 0, near_x, image_height}, :x, background, threshold),
         {:ok, top} <- near_edge(image, {0, 0, image_width, near_y}, :y, background, threshold),
         {:ok, right} <-
           far_edge(
             image,
             {far_x, 0, image_width - far_x, image_height},
             :x,
             background,
             threshold
           ),
         {:ok, bottom} <-
           far_edge(
             image,
             {0, far_y, image_width, image_height - far_y},
             :y,
             background,
             threshold
           ) do
      {:ok, {left, top, right - left, bottom - top}}
    else
      :unclear -> find_trim(image, background, threshold)
      {:error, _reason} = error -> error
    end
  end

  # The left or top edge of the content in a strip that starts at the border.
  defp near_edge(image, {x, y, width, height} = area, axis, background, threshold) do
    with {:ok, {left, top, box_width, box_height}} <-
           strip_box(image, area, background, threshold) do
      {start, extent} = if axis == :x, do: {left, width}, else: {top, height}

      if box_width > 0 and box_height > 0 and start < extent - @preview_shrink,
        do: {:ok, start + if(axis == :x, do: x, else: y)},
        else: :unclear
    end
  end

  # The right or bottom edge, exclusive, in a strip that ends at the border.
  defp far_edge(image, {x, y, _width, _height} = area, axis, background, threshold) do
    with {:ok, {left, top, box_width, box_height}} <-
           strip_box(image, area, background, threshold) do
      start = if axis == :x, do: left, else: top
      finish = start + if(axis == :x, do: box_width, else: box_height)

      if box_width > 0 and box_height > 0 and finish > @preview_shrink,
        do: {:ok, finish + if(axis == :x, do: x, else: y)},
        else: :unclear
    end
  end

  defp strip_box(image, {x, y, width, height}, background, threshold) do
    with {:ok, strip} <- Operation.extract_area(image, x, y, width, height),
         do: find_trim(strip, background, threshold)
  end

  defp find_trim(image, background, threshold),
    do: Operation.find_trim(image, background: background, threshold: threshold)

  defp crop_or_passthrough(_original, state, _left, _top, 0, _height), do: {:ok, state}
  defp crop_or_passthrough(_original, state, _left, _top, _width, 0), do: {:ok, state}

  defp crop_or_passthrough(original, state, left, top, width, height) do
    case Image.crop(original, left, top, width, height) do
      {:ok, cropped} -> {:ok, set_image(state, cropped)}
      {:error, error} -> {:error, error}
    end
  end

  defp prepare(image) do
    with {:ok, srgb} <- to_srgb(image) do
      flatten_alpha(srgb)
    end
  end

  # A tagged image compares through its profile, so colors match in sRGB.
  defp to_srgb(image) do
    with {:ok, image} <- WorkingColor.to_srgb(image), do: to_srgb_values(image)
  end

  defp to_srgb_values(image) do
    case VixImage.interpretation(image) do
      :VIPS_INTERPRETATION_sRGB -> {:ok, image}
      _ -> Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    end
  end

  defp flatten_alpha(image) do
    if Image.has_alpha?(image) do
      Image.flatten(image, background: @magenta)
    else
      {:ok, image}
    end
  end

  defp background_list(:auto, prepared), do: Image.get_pixel(prepared, 0, 0)

  defp background_list(%Color{channels: channels}, _prepared) do
    {:ok, Tuple.to_list(channels)}
  end

  # equal_hor/equal_ver: grow the box on the more-trimmed side so opposite margins
  # equal the smaller inset. Mirrors imgproxy vips.c lines 927-949. `near` is the
  # near-edge margin (left/top), `extent` the box size, `total` the original axis.
  defp equalize(false, near, extent, _total), do: {near, extent}

  defp equalize(true, near, extent, total) do
    far = total - near - extent
    diff = far - near

    cond do
      diff > 0 -> {near, extent + diff}
      diff < 0 -> {far, extent - diff}
      true -> {near, extent}
    end
  end
end

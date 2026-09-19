defmodule ImagePipe.Transform.Operation.Trim do
  @moduledoc """
  Executable uniform-border trim. Replicates imgproxy `vips_trim`
  (`vips/vips.c`): prepare a detection copy (sRGB convert; magenta-flatten alpha),
  resolve the background (top-left pixel for `:auto`, else the explicit color),
  `find_trim`, symmetrize via `equal_hor`/`equal_ver`, return unchanged on a
  degenerate box, and extract from the original image.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Plan.Color
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

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

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :trim

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    original = state.image
    orig_w = Image.width(original)
    orig_h = Image.height(original)

    with {:ok, prepared} <- prepare(original),
         {:ok, background} <- background_list(op.background, prepared),
         {:ok, {left, top, width, height}} <-
           Operation.find_trim(prepared, background: background, threshold: op.threshold),
         {left, width} = equalize(op.equal_hor, left, width, orig_w),
         {top, height} = equalize(op.equal_ver, top, height, orig_h),
         {:ok, result} <- crop_or_passthrough(original, state, left, top, width, height) do
      {:ok, result}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

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

  defp to_srgb(image) do
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

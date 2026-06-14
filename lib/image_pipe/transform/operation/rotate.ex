defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Executable rotation. Applies an optional horizontal mirror (IIIF `!`) *before*
  rotating clockwise by `angle` degrees.

  Exact right-angle multiples use the lossless `vips_rot` primitive (no resample,
  no #211 background seam — even when mirrored). Any other angle uses the affine
  `vips_rotate` resampler with a transparent background, so the exposed corners
  are transparent; a non-alpha output format flattens that transparency onto the
  configured `Plan.Output.flatten_background` at encode time (IIIF defines no
  per-request fill knob).

  Materializing op: rotation reads pixels out of row order, so it cannot run over
  a sequential decode. As a `requires_materialization?: true` op it is preceded by
  `Chain`/`Materializer`'s orientation-applying flush, so it always sees the
  EXIF-corrected display frame.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:angle]
  defstruct [:angle, mirror: false]

  @type t :: %__MODULE__{angle: number(), mirror: boolean()}

  # Float RGBA: vips_rotate's `background` is an array of doubles; a 4-element
  # value fills the exposed corners fully transparent on an alpha image.
  @transparent [0.0, 0.0, 0.0, 0.0]

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: angle, mirror: mirror}, %State{} = state) do
    with {:ok, image} <- maybe_mirror(state.image, mirror),
         {:ok, image} <- rotate(image, angle) do
      {:ok, set_image(state, image)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp maybe_mirror(image, false), do: {:ok, image}
  defp maybe_mirror(image, true), do: Image.flip(image, :horizontal)

  # Angles arrive pre-normalized to integers for whole numbers (folded by the
  # Plan.Operation.rotate/2 constructor and the IIIF grammar), so exact right-angle
  # multiples match these integer clauses and take the lossless vips_rot path; only
  # genuinely fractional angles reach the affine clause below.
  #
  # Exact right angles: the lossless vips_rot primitive (same one OrientationFlush
  # and imgproxy use). Direct Vix call — the `image` facade has no exact-rotate.
  defp rotate(image, 0), do: {:ok, image}
  defp rotate(image, 90), do: Operation.rot(image, :VIPS_ANGLE_D90)
  defp rotate(image, 180), do: Operation.rot(image, :VIPS_ANGLE_D180)
  defp rotate(image, 270), do: Operation.rot(image, :VIPS_ANGLE_D270)

  # Arbitrary angle: affine resample with transparent corners. Ensure an alpha
  # band, then premultiply -> rotate -> unpremultiply (vips_rotate does NOT
  # premultiply; rotating un-premultiplied RGBA dark-fringes the resampled edges,
  # the same reason blur/sharpen premultiply). Call Vix directly: the `image`
  # facade's Image.rotate/3 rejects a 4-element RGBA background.
  # Unlike blur.ex (which premultiplies only when alpha already exists), arbitrary
  # rotation always ensures alpha so that exposed corners can be fully transparent.
  defp rotate(image, angle) do
    with {:ok, rgba} <- ensure_alpha(image),
         band_format = VipsImage.format(rgba),
         {:ok, premultiplied} <- Operation.premultiply(rgba),
         {:ok, cast} <- Operation.cast(premultiplied, band_format),
         {:ok, rotated} <- Operation.rotate(cast, angle * 1.0, background: @transparent),
         {:ok, unpremultiplied} <- Operation.unpremultiply(rotated) do
      Operation.cast(unpremultiplied, band_format)
    end
  end

  defp ensure_alpha(image) do
    if Image.has_alpha?(image), do: {:ok, image}, else: Image.add_alpha(image, :opaque)
  end
end

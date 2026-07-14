defmodule ImagePipe.Output.Terminal.Blurhash do
  @moduledoc """
  Shared blurhash terminal computation (`ImagePipe.Output.Terminal.Blurhash`).

  `identity/0` contributes the terminal computation's identity tuple to
  `representation` material, so a change in the terminal's behavior reaches
  the cache key and ETag. `compute/1` is the actual pixel computation: it
  normalizes whatever image it is handed into a FIXED terminal pixel space —
  sRGB, tone-mapped, independent of the decoded image's color profile — and
  then runs a 4x3-component BlurHash encode over that normalized image.

  Normalization is deliberately NOT a caller-supplied option: callers do not
  (and must not) apply working-space color management before handing pixels
  here, so this module owns a proper, profile-aware conversion. A decoded
  image whose embedded ICC profile is still intact (a caller that never
  imports color into a working space) must still resolve to the same
  terminal pixel space as an equivalent image that was already sRGB:
  reinterpreting the raw bytes without reading the embedded profile would
  produce a different, wrong, hash for visually identical content.
  """

  alias Vix.Vips.Image, as: Vimage

  @doc """
  The terminal computation's identity: fixed 4x3 blurhash components. Enters
  `Representation.IdentityMaterial.representation` so a future component
  change (or any other behavior change) rides identity via this tuple, not
  luck.
  """
  @spec identity() :: {:blurhash, 1}
  def identity, do: {:blurhash, 1}

  @doc """
  Computes a BlurHash string for `image`.

  Owns two responsibilities: normalizing `image` into the fixed terminal
  pixel space (`to_terminal_pixel_space/1`) and running the 4x3-component
  BlurHash encode (`Image.Blurhash.encode/2`) over the normalized result.
  """
  @spec compute(Vimage.t()) :: {:ok, String.t()} | {:error, term()}
  def compute(%Vimage{} = image) do
    with {:ok, normalized} <- to_terminal_pixel_space(image) do
      Image.Blurhash.encode(normalized, x_components: 4, y_components: 3)
    end
  end

  @doc """
  Normalizes `image` into the fixed terminal pixel space: sRGB, tone-mapped,
  independent of the decoded image's color profile, flattened to 3 bands (no
  alpha — `Image.Blurhash.encode/2` only accepts 3-band images), 8-bit.

  Exposed (not `@doc false`) so the pixel-space-invariance property — two
  images with identical visual content but different embedded color
  profiles normalize to close (and, when the profile conversion happens to
  be exact, byte-identical) pixels — is independently assertable in tests,
  not just inferable from the final hash string.
  """
  @spec to_terminal_pixel_space(Vimage.t()) :: {:ok, Vimage.t()} | {:error, term()}
  def to_terminal_pixel_space(%Vimage{} = image) do
    with {:ok, srgb} <- to_srgb(image),
         {:ok, flattened} <- Image.flatten(srgb) do
      Image.cast(flattened, {:u, 8})
    end
  end

  # ICC-aware conversion: when the source carries an embedded profile,
  # `Image.to_colorspace/3` (libvips `icc_transform`) reads it as the input
  # profile and converts to sRGB — a genuine colorimetric conversion, not a
  # byte reinterpretation. Sources without an embedded profile (the common
  # case) fall back to the cheaper interpretation-based `to_colorspace/2`
  # (libvips `colourspace`), which still handles non-RGB interpretations
  # (CMYK, LAB, linear-light scRGB HDR) by converting/companding into sRGB —
  # the "tone-mapped" half of the fixed pixel space for HDR sources.
  defp to_srgb(image) do
    if embedded_icc_profile?(image) do
      Image.to_colorspace(image, :srgb, [])
    else
      Image.to_colorspace(image, :srgb)
    end
  end

  defp embedded_icc_profile?(image) do
    case Vimage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) -> true
      _not_present -> false
    end
  end
end

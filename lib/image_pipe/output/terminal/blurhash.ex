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

  alias ImagePipe.Output.Terminal.PixelSpace
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
  pixel space (`ImagePipe.Output.Terminal.PixelSpace`) and running the 4x3-component
  BlurHash encode (`Image.Blurhash.encode/2`) over the normalized result.
  """
  @spec compute(Vimage.t()) :: {:ok, String.t()} | {:error, term()}
  def compute(%Vimage{} = image) do
    with {:ok, normalized} <- PixelSpace.normalize(image) do
      Image.Blurhash.encode(normalized, x_components: 4, y_components: 3)
    end
  end
end

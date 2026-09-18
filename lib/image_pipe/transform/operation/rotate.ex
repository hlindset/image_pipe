defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Executable clockwise rotation by `angle` degrees.

  Exact right-angle multiples use the lossless `vips_rot` primitive (no resample,
  no background seam). Any other angle uses the affine
  `vips_rotate` resampler with a transparent background, so the exposed corners
  are transparent; a non-alpha output format flattens that transparency onto the
  configured `Output.Policy.flatten_background` at encode time.

  Materializing op: rotation reads pixels out of row order, so it cannot run over
  a sequential decode. As a `requires_materialization?: true` op it is preceded by
  `Chain`/`Materializer`'s copy-to-memory; when an orientation is pending, the
  executor flushes it before this op, so rotation sees the corrected display
  frame.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @enforce_keys [:angle]
  defstruct [:angle]

  @type t :: %__MODULE__{angle: number()}

  # Float RGBA: vips_rotate's `background` is an array of doubles; a 4-element
  # value fills the exposed corners fully transparent on an alpha image.
  @transparent [0.0, 0.0, 0.0, 0.0]

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case rotate(state.image, angle) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Angles arrive pre-normalized to integers for whole numbers, so exact
  # right-angle multiples match this clause and take Image.rotate/3's discrete vips_rot fast
  # path — lossless, no resample, no #211 background seam, the same primitive
  # OrientationFlush and imgproxy use. Only genuinely fractional angles reach the
  # affine clause below.
  # Dialyzer can't see through Vix's generated Operation typings (rotate).
  @dialyzer {:no_fail_call, rotate: 2}
  defp rotate(image, 0), do: {:ok, image}
  defp rotate(image, angle) when angle in [90, 180, 270], do: Image.rotate(image, angle)

  # Arbitrary angle: affine resample with transparent corners. Always ensure an
  # alpha band (even for opaque input) so the exposed corners can be fully
  # transparent, then rotate over a transparent background. vips_rotate premultiplies
  # the alpha itself — it is built on vips_affine, which premultiplies before
  # resampling and unpremultiplies after — so we must NOT premultiply here: doing it
  # on top of vips_rotate double-premultiplies and inflates the colour of any
  # semi-transparent pixels. Call Vix directly: the `image` facade's Image.rotate/3
  # rejects a 4-element RGBA background.
  defp rotate(image, angle) do
    with {:ok, rgba} <- ensure_alpha(image) do
      Operation.rotate(rgba, angle * 1.0, background: @transparent)
    end
  end

  defp ensure_alpha(image) do
    if Image.has_alpha?(image), do: {:ok, image}, else: Image.add_alpha(image, :opaque)
  end
end

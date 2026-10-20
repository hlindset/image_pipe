defmodule ImagePipe.Transform.Operation.Rotate do
  # Clockwise arbitrary-angle rotation with transparent corners.
  #
  # Non-alpha output formats flatten the corners onto white at encoding.
  #
  # Rotation reads pixels out of row order, so the executor's step table
  # (`Executor.Step.random_access?/1`) copies the input to RAM first. The executor
  # flushes pending orientation before this operation so it sees display-frame pixels.
  # The result stays lazy until a downstream resize buffers it, avoiding repeated
  # affine evaluation while allowing crop-only requests to evaluate a small region.
  @moduledoc false

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.Alpha
  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.State
  alias Vix.Vips.Interpolate
  alias Vix.Vips.Operation

  @enforce_keys [:angle]
  defstruct [:angle]

  @type t :: %__MODULE__{angle: number()}

  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case rotate(state.image, angle) do
      {:ok, image} ->
        {:ok, %{set_image(state, image) | rebuffer?: true}}

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  # Add alpha for transparent corners: the affine fills with zeros, which is
  # transparent once the image has alpha. Bicubic keeps edges slightly crisper
  # than libvips' default bilinear.
  #
  # Workaround for `image` 0.72.0: `Image.rotate/3` casts the unpremultiplied
  # float result back to the band format, which truncates, so a semi-transparent
  # [200, 120, 37, 100] comes back as [200, 119, 37, 100]. This runs the same
  # premultiplied affine through the helper, which rounds instead. No upstream
  # fix yet (image_plug-qeqt).
  defp rotate(image, angle) do
    radians = angle * :math.pi() / 180.0
    matrix = [:math.cos(radians), -:math.sin(radians), :math.sin(radians), :math.cos(radians)]

    with {:ok, with_alpha} <- Alpha.ensure(image),
         {:ok, bicubic} <- Interpolate.new("bicubic") do
      AlphaPremultiply.with_alpha_premultiplied(with_alpha, fn premultiplied ->
        Operation.affine(premultiplied, matrix,
          interpolate: bicubic,
          extend: :VIPS_EXTEND_BACKGROUND,
          premultiplied: true
        )
      end)
    end
  end
end

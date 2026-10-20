defmodule ImagePipe.Transform.Operation.Resize do
  # Resizes the current image to concrete pixel dimensions resolved by the
  # executor, with a libvips kernel. Cover requests use a separate crop after
  # this operation.
  @moduledoc false

  import ImagePipe.Transform.Geometry, only: [image_height: 1, image_width: 1]
  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.{Materializer, State, WorkLimits}
  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias Vix.Vips.Operation

  @enforce_keys [:width, :height]
  defstruct [:width, :height, kernel: :lanczos3]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          kernel: ImagePipe.Plan.Spec.Group.kernel()
        }

  def execute(%__MODULE__{width: width, height: height} = resize, %State{} = state) do
    with :ok <- WorkLimits.resize(state, width, height) do
      do_resize(state, resize)
    end
  end

  defp do_resize(state, resize) do
    case resize_image(state, resize) do
      {:ok, %State{} = state} ->
        # The residual resize completes the downscale. Later groups use this
        # image's dimensions without the initial decode's preshrink factor.
        {:ok, %State{state | source_dimensions: nil, decode_shrink: nil}}

      {:error, {tag, _reason}} = error when tag in [:decode, :transform] ->
        error

      {:error, reason} ->
        {:error, {__MODULE__, reason}}
    end
  end

  defp resize_image(%State{} = state, %__MODULE__{width: width, height: height, kernel: kernel}) do
    source_width = image_width(state)
    source_height = image_height(state)

    case width == source_width and height == source_height do
      true ->
        {:ok, state}

      false ->
        with {:ok, state} <- prepare_resize(state),
             {:ok, image} <-
               resize(state.image, width / source_width, height / source_height, kernel) do
          {:ok, set_image(state, image)}
        end
    end
  end

  # Workaround for `image` 0.72.0: `Image.resize/3` casts the unpremultiplied
  # float result back to the band format, which truncates, so a semi-transparent
  # [200, 120, 37, 100] comes back as [200, 119, 37, 100]. The premultiply
  # helper rounds instead. No upstream fix yet (image_plug-qeqt).
  defp resize(image, scale, vscale, kernel) do
    AlphaPremultiply.with_alpha_premultiplied(
      image,
      &Operation.resize(&1, scale, vscale: vscale, kernel: vips_kernel(kernel))
    )
  end

  defp vips_kernel(:nearest), do: :VIPS_KERNEL_NEAREST
  defp vips_kernel(:linear), do: :VIPS_KERNEL_LINEAR
  defp vips_kernel(:cubic), do: :VIPS_KERNEL_CUBIC
  defp vips_kernel(:mitchell), do: :VIPS_KERNEL_MITCHELL
  defp vips_kernel(:lanczos2), do: :VIPS_KERNEL_LANCZOS2
  defp vips_kernel(:lanczos3), do: :VIPS_KERNEL_LANCZOS3
  defp vips_kernel(:mks2013), do: :VIPS_KERNEL_MKS2013
  defp vips_kernel(:mks2021), do: :VIPS_KERNEL_MKS2021

  # Resampling a lazy affine rotation or convolution repeatedly evaluates
  # overlapping regions. Buffer here so an intervening crop can reduce the
  # work first.
  defp prepare_resize(%State{rebuffer?: true} = state),
    do: Materializer.materialize(state)

  defp prepare_resize(%State{} = state), do: {:ok, state}
end

defmodule ImagePipe.Transform.Operation.GaussianBlur do
  # Gaussian blur shared by Blur and ProgressiveBlur.
  #
  # libvips' integer path for 8-bit input uses a coarse mask whose weights
  # don't sum to one, so it shifts flat areas by up to 2% at some sigmas. Below
  # @approximate_sigma the blur uses float precision and rounds back to the
  # input format. From there libvips' approximate path is exact on flat areas,
  # differs by under 3 levels elsewhere, and is faster: 3x at sigma 10 and 7x
  # at sigma 20 on float input.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @approximate_sigma 4.0
  @min_amplitude 0.2

  @spec blur(VipsImage.t(), number()) :: {:ok, VipsImage.t()} | {:error, term()}
  def blur(%VipsImage{} = image, sigma) do
    format = VipsImage.format(image)

    with {:ok, blurred} <-
           Operation.gaussblur(image, sigma * 1.0,
             "min-ampl": @min_amplitude,
             precision: precision(sigma)
           ) do
      in_format(blurred, format)
    end
  end

  defp precision(sigma) when sigma >= @approximate_sigma, do: :VIPS_PRECISION_APPROXIMATE
  defp precision(_sigma), do: :VIPS_PRECISION_FLOAT

  defp in_format(image, format) do
    case VipsImage.format(image) do
      ^format ->
        {:ok, image}

      _float ->
        with {:ok, rounded} <- Operation.round(image, :VIPS_OPERATION_ROUND_RINT),
             do: Operation.cast(rounded, format)
    end
  end
end

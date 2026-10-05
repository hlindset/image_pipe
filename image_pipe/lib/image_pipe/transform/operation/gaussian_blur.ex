defmodule ImagePipe.Transform.Operation.GaussianBlur do
  # Gaussian blur shared by Blur and ProgressiveBlur.
  #
  # Images with alpha are blurred as float premultiplied pixels, where libvips'
  # exact convolution is slow. From @approximate_sigma its approximate path is
  # faster (3x at sigma 10, 7x at sigma 20) and differs by under 3 levels;
  # below it, it is slower. 8-bit input already takes libvips' integer path.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @approximate_sigma 4.0
  @min_amplitude 0.2

  @spec blur(VipsImage.t(), number()) :: {:ok, VipsImage.t()} | {:error, term()}
  def blur(%VipsImage{} = image, sigma) do
    Operation.gaussblur(
      image,
      sigma * 1.0,
      ["min-ampl": @min_amplitude] ++ precision(image, sigma)
    )
  end

  defp precision(image, sigma) do
    if sigma >= @approximate_sigma and
         VipsImage.format(image) in [:VIPS_FORMAT_FLOAT, :VIPS_FORMAT_DOUBLE],
       do: [precision: :VIPS_PRECISION_APPROXIMATE],
       else: []
  end
end

defmodule ImagePipe.Output.ContentClassifier do
  @moduledoc """
  Cheap content classifier for the autoquality crop-offset policy.

  Returns `:photo` (continuous-tone photographic content) or `:graphic`
  (discrete-tone synthetic content: screenshots, UI, text, charts, line art).
  Derived entirely from runtime image inspection on a 512 px downsample, like
  EXIF auto-orient and input color management — not a `Plan.Operation`.

  `:graphic` is the **safe fallback**: misclassification is asymmetric (a photo
  read as graphic only inflates a file slightly; a graphic read as photo ships
  visible text/edge damage at the lean offset), so any internal libvips error
  returns `:graphic` rather than failing the request. The graphic→photo error is
  the one that must stay at zero (validated on the labeled cohort by
  `mix autoquality.bench --part m`).
  """

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @type class :: :photo | :graphic
  @type features :: %{palette_ent: float(), nat_var: float()}

  # 512 px long-edge downsample: separation is near-invariant 256→1024 px
  # (palette_ent is a histogram measure) and screen→photo stays 0 at every size,
  # so 512 buys ~all the accuracy at ~60% the cost (bench Part M).
  @downsample 512

  # Gradient-magnitude thresholds (bench Part M): below @flat = flat fill, above
  # @hard = hard edge; nat_var is the mid-band fraction between them.
  @flat_thresh 8.0
  @hard_thresh 64.0

  # Sobel kernels (horizontal / vertical).
  @k0 [[1.0, 0.0, -1.0], [2.0, 0.0, -2.0], [1.0, 0.0, -1.0]]
  @k90 [[1.0, 2.0, 1.0], [0.0, 0.0, 0.0], [-1.0, -2.0, -1.0]]

  # Photo-side Youden thresholds, pinned by `mix autoquality.bench --part m`.
  # Photos read HIGH on both features (cohort medians palette_ent 0.909/0.393,
  # nat_var 0.411/0.110); :photo requires BOTH to clear their threshold, else the
  # safe :graphic fallback.
  @palette_photo_threshold 0.62
  @nat_var_photo_threshold 0.22

  @doc """
  Classify a finalized image. Never raises; any libvips failure → `:graphic`.
  """
  @spec classify(VixImage.t()) :: {class(), features()}
  def classify(%VixImage{} = image) do
    case features(image) do
      {:ok, %{palette_ent: pe, nat_var: nv} = feats} ->
        class =
          if pe >= @palette_photo_threshold and nv >= @nat_var_photo_threshold,
            do: :photo,
            else: :graphic

        {class, feats}

      :error ->
        {:graphic, %{palette_ent: 0.0, nat_var: 0.0}}
    end
  end

  defp features(image) do
    extract(image)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp extract(image) do
    scale = min(1.0, @downsample / max(VixImage.width(image), VixImage.height(image)))

    with {:ok, small} <- Operation.resize(image, scale),
         {:ok, g8lazy} <- Operation.colourspace(small, :VIPS_INTERPRETATION_B_W),
         # Pull the downsample+grayscale into RAM once so the convolutions and the
         # histogram read the small buffer instead of re-evaluating the resize.
         {:ok, g8} <- VixImage.copy_memory(g8lazy),
         {:ok, gf} <- Operation.cast(g8, :VIPS_FORMAT_FLOAT),
         {:ok, c0} <- conv(gf, @k0),
         {:ok, c90} <- conv(gf, @k90),
         {:ok, mag} <- gradient_magnitude(c0, c90),
         {:ok, flat} <- frac(mag, :VIPS_OPERATION_RELATIONAL_LESS, @flat_thresh),
         {:ok, hard} <- frac(mag, :VIPS_OPERATION_RELATIONAL_MORE, @hard_thresh),
         {:ok, hist} <- Operation.hist_find(g8),
         {:ok, ent} <- Operation.hist_entropy(hist) do
      {:ok, %{palette_ent: ent / 8.0, nat_var: max(0.0, 1.0 - flat - hard)}}
    end
  end

  defp conv(gf, kernel) do
    with {:ok, mask} <- VixImage.new_from_list(kernel), do: Operation.conv(gf, mask)
  end

  defp gradient_magnitude(c0, c90) do
    with {:ok, sq0} <- Operation.multiply(c0, c0),
         {:ok, sq90} <- Operation.multiply(c90, c90),
         {:ok, sumsq} <- Operation.add(sq0, sq90) do
      Operation.math2_const(sumsq, :VIPS_OPERATION_MATH2_POW, [0.5])
    end
  end

  # Fraction of pixels passing a relational test on the gradient magnitude. The
  # boolean image is 255 where true, so avg / 255 is the fraction.
  defp frac(mag, op, threshold) do
    with {:ok, bool} <- Operation.relational_const(mag, op, [threshold]),
         {:ok, avg} <- Operation.avg(bool) do
      {:ok, avg / 255.0}
    end
  end
end

defmodule ImagePipe.Cache.Cost do
  # Estimates what a stored output cost to render, in reference microseconds,
  # from facts the render reports in its debug info. Admission scores entries
  # by it, so only the ratios between estimates matter. A measured time would
  # vary with load, and a streamed encode is mostly unfinished when the entry
  # is opened, so the estimate stands in for both.
  #
  # An estimate is a sum of features, each an amount times a weight:
  #
  #   request   one per render: fetching, planning, buffering
  #   decode    source pixels × the source format's weight, which includes
  #             the resize and conversions after it. Shrink-on-load saves
  #             little for JPEG, so source pixels predict it. WebP decodes
  #             at the shrunk size, and an SVG renders at it, so those count
  #             decoded pixels.
  #   alpha     decoded pixels again when the source has an alpha channel
  #   op        decoded pixels for an operation before the resize (trim, a
  #             rotation other than a quarter turn, a guided crop), output
  #             pixels for an effect after it
  #   encode    output pixels × the encoder's weight at its effort
  #   search    each autoquality iteration encodes again, decodes the
  #             candidate and scores it (all pixels, or 512 × 512 tiles for
  #             the crop scorer)
  #   detect    one per group whose crop runs a detector
  #
  # A placeholder or info response is one constant per kind. Pixel amounts
  # are in thousands, so a pixel weight is in milliseconds per megapixel. The
  # weights are the geometric mean of `bench/cost_calibration.exs` fits on x86
  # and ARM CI runners (its `--combine`), measured with one libvips thread per
  # render: CPU time, which is what a render costs a loaded server whatever
  # its core count. Efforts it doesn't measure are
  # interpolated, HEIF decodes like AVIF, and JPEG 2000 and SVG keep their
  # first guesses' ratio to PNG. Detection and watermarks aren't measured, and
  # a guided crop fitted to about nothing. A progressive JPEG decodes about
  # twice as slowly as a baseline one of the same size.
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @weights %{
    :alpha => 7.7,
    :detect => 150_000,
    :metric => 17,
    :request => 4_000,
    {:decode, :avif} => 5.1,
    {:decode, :gif} => 2.1,
    {:decode, :heif} => 4.8,
    {:decode, :jpeg} => 0.83,
    {:decode, :jpeg2000} => 9.3,
    {:decode, :jpeg_progressive} => 1.7,
    {:decode, :jpeg_xl} => 11,
    {:decode, :png} => 4.2,
    {:decode, :svg} => 8.6,
    {:decode, :tiff} => 1.6,
    {:decode, :webp} => 18,
    {:encode, :jpeg} => 6.9,
    {:encode, :png} => 32,
    {:encode, :png_palette} => 70,
    {:op, :blur} => 18,
    {:op, :crop_guided} => 1,
    {:op, :pixelate} => 5,
    {:op, :progressive_blur} => 110,
    {:op, :rotate} => 24,
    {:op, :sharpen} => 35,
    {:op, :trim} => 7.1,
    {:op, :watermark} => 5,
    {:terminal, :blurhash} => 9_000,
    {:terminal, :info} => 870,
    {:terminal, :lqip_css} => 11_000,
    {:encode, :avif, 0} => 20,
    {:encode, :avif, 1} => 33,
    {:encode, :avif, 2} => 75,
    {:encode, :avif, 3} => 110,
    {:encode, :avif, 4} => 570,
    {:encode, :avif, 5} => 790,
    {:encode, :avif, 6} => 1_500,
    {:encode, :avif, 7} => 2_000,
    {:encode, :avif, 8} => 2_800,
    {:encode, :avif, 9} => 3_600,
    {:encode, :webp, 0} => 12,
    {:encode, :webp, 1} => 12,
    {:encode, :webp, 2} => 17,
    {:encode, :webp, 3} => 20,
    {:encode, :webp, 4} => 32,
    {:encode, :webp, 5} => 43,
    {:encode, :webp, 6} => 78
  }

  @default_effort %{webp: 4, avif: 3}
  @tile_kpx 512 * 512 / 1_000

  @doc "Estimates a rendered image's cost from its debug info and output."
  @spec render(Info.t(), Resolved.t()) :: non_neg_integer()
  def render(%Info{} = info, %Resolved{} = output), do: info |> features(output) |> total()

  @doc "Estimates the cost of a placeholder or info response."
  @spec terminal(:info | :blurhash | :lqip_css) :: pos_integer()
  def terminal(kind), do: total(%{{:terminal, kind} => 1})

  @doc false
  # The amount of each feature a render did, for `render/2` and calibration.
  @spec features(Info.t(), Resolved.t()) :: %{term() => number()}
  def features(%Info{} = info, %Resolved{} = output) do
    output_kpx = kpx(info.output_width, info.output_height)
    decoded_kpx = decoded_kpx(info)
    iterations = iterations(info)

    [
      {:request, 1},
      {:alpha, if(info.source_alpha?, do: decoded_kpx, else: 0)},
      {source_decode_feature(info), decode_kpx(info, decoded_kpx)},
      {encoder(output.format, output.encoder_options), output_kpx * (1 + iterations)},
      {decode_feature(output.format), output_kpx * iterations},
      {:metric, scored_kpx(info.aq, output_kpx) * iterations},
      {:detect, info.detections},
      {{:op, :rotate}, decoded_kpx * info.rotations}
      | operations(info.pipeline, decoded_kpx, output_kpx)
    ]
    |> Enum.reject(fn {_feature, amount} -> amount == 0 end)
    |> Enum.reduce(%{}, fn {feature, amount}, acc ->
      Map.update(acc, feature, amount, &(&1 + amount))
    end)
  end

  @doc false
  def weights, do: @weights

  defp total(features) do
    features
    |> Enum.reduce(0, fn {feature, amount}, sum ->
      sum + amount * Map.fetch!(@weights, feature)
    end)
    |> round()
  end

  defp kpx(width, height) when is_integer(width) and is_integer(height),
    do: width * height / 1_000

  defp kpx(_width, _height), do: 0

  defp decoded_kpx(%Info{source_width: width, source_height: height, shrink: shrink}) do
    %{w: shrink_w, h: shrink_h} = shrink || %{w: 1.0, h: 1.0}
    kpx(width, height) / (shrink_w * shrink_h)
  end

  defp decode_kpx(%Info{source_format: format}, decoded_kpx) when format in [:webp, :svg],
    do: decoded_kpx

  defp decode_kpx(%Info{} = info, _decoded_kpx), do: kpx(info.source_width, info.source_height)

  # Operations with a cost of their own. The others are cheap next to the
  # decode and encode.
  @before_resize [:trim, :crop_guided]
  @after_resize [:blur, :progressive_blur, :sharpen, :pixelate, :watermark]

  defp operations(pipeline, decoded_kpx, output_kpx) do
    for name <- pipeline, name in @before_resize or name in @after_resize do
      {{:op, name}, if(name in @before_resize, do: decoded_kpx, else: output_kpx)}
    end
  end

  defp source_decode_feature(%Info{source_format: :jpeg, source_progressive?: true}),
    do: {:decode, :jpeg_progressive}

  defp source_decode_feature(%Info{source_format: format}), do: decode_feature(format)

  # A format without its own weight decodes like PNG.
  defp decode_feature(format) do
    feature = {:decode, format}
    if Map.has_key?(@weights, feature), do: feature, else: {:decode, :png}
  end

  defp encoder(:png, %{palette: true}), do: {:encode, :png_palette}

  defp encoder(format, options) when format in [:webp, :avif],
    do: {:encode, format, effort(options, Map.fetch!(@default_effort, format))}

  defp encoder(format, _options), do: {:encode, format}

  defp effort(%{effort: effort}, _default) when is_integer(effort), do: effort
  defp effort(_options, default), do: default

  defp iterations(%Info{aq: %{iterations: iterations}}) when is_integer(iterations),
    do: iterations

  defp iterations(_info), do: 0

  defp scored_kpx(%{scorer: :crop, tiles: tiles}, output_kpx) when is_integer(tiles),
    do: min(output_kpx, tiles * @tile_kpx)

  defp scored_kpx(_aq, output_kpx), do: output_kpx
end

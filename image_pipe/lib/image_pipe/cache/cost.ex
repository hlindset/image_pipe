defmodule ImagePipe.Cache.Cost do
  # Estimates what a stored output cost to render, in reference microseconds,
  # from facts the render reports in its debug info. Admission scores entries
  # by it, so only the ratios between estimates matter. A measured time would
  # vary with load, and a streamed encode is mostly unfinished when the entry
  # is opened, so the estimate stands in for both.
  #
  # The weights are milliseconds per megapixel on one reference core. They
  # come from the decode, encode and autoquality benchmarks, and the
  # calibration task refines them. An estimate is a sum of classes:
  #
  #   decode   decoded pixels (after shrink-on-load) × the source's weight
  #   encode   output pixels × the output's weight, which grows with effort
  #   search   each autoquality iteration encodes, decodes the candidate and
  #            scores it (all pixels, or 512 × 512 tiles for the crop scorer)
  #   detect   a constant per group whose crop runs object detection
  #
  # A placeholder or info response costs its decode and a constant.
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @decode_ms_per_mp %{
    jpeg: 6,
    png: 15,
    webp: 12,
    avif: 40,
    heif: 40,
    jpeg_xl: 25,
    jpeg2000: 60,
    tiff: 5,
    gif: 10,
    svg: 20
  }
  @default_decode_ms_per_mp 15

  @jpeg_encode_ms_per_mp 8
  @png_encode_ms_per_mp 40
  @png_palette_encode_ms_per_mp 120
  @default_webp_effort 4
  @default_avif_effort 4

  @metric_ms_per_mp 30
  @tile_px 512 * 512

  @detect_us 150_000

  @terminal_us %{info: 5_000, blurhash: 20_000, lqip_css: 20_000}

  @doc "Estimates a rendered image's cost from its debug info and output."
  @spec render(Info.t(), Resolved.t()) :: non_neg_integer()
  def render(%Info{} = info, %Resolved{} = output) do
    output_px = pixels(info.output_width, info.output_height)
    encode = output_px * encode_weight(output.format, output.encoder_options)

    round(decode(info) + encode + search(info, output_px, encode) + info.detections * @detect_us)
  end

  @doc "Estimates the cost of a placeholder or info response."
  @spec terminal(:info | :blurhash | :lqip_css) :: pos_integer()
  def terminal(kind), do: Map.fetch!(@terminal_us, kind)

  # Thousands of pixels, so that times a weight in ms per megapixel gives
  # microseconds.
  defp pixels(width, height) when is_integer(width) and is_integer(height),
    do: width * height / 1_000

  defp pixels(_width, _height), do: 0.0

  defp decode(%Info{source_width: width, source_height: height} = info) do
    %{w: shrink_w, h: shrink_h} = info.shrink || %{w: 1.0, h: 1.0}
    pixels(width, height) / (shrink_w * shrink_h) * decode_weight(info.source_format)
  end

  defp decode_weight(format), do: Map.get(@decode_ms_per_mp, format, @default_decode_ms_per_mp)

  defp encode_weight(:jpeg, _options), do: @jpeg_encode_ms_per_mp
  defp encode_weight(:png, %{palette: true}), do: @png_palette_encode_ms_per_mp
  defp encode_weight(:png, _options), do: @png_encode_ms_per_mp

  defp encode_weight(:webp, options),
    do: 20 * :math.pow(1.35, effort(options, @default_webp_effort))

  defp encode_weight(:avif, options),
    do: 60 * :math.pow(1.5, effort(options, @default_avif_effort))

  defp effort(%{effort: effort}, _default) when is_integer(effort), do: effort
  defp effort(_options, default), do: default

  # The final encode is counted once already, so each iteration adds its
  # encode, the candidate's decode and the metric.
  defp search(%Info{aq: %{iterations: iterations} = aq} = info, output_px, encode)
       when is_integer(iterations) and iterations > 0 do
    candidate_decode = output_px * decode_weight(info.output_format)
    metric = scored_pixels(aq, output_px) * @metric_ms_per_mp
    iterations * (encode + candidate_decode + metric)
  end

  defp search(_info, _output_px, _encode), do: 0.0

  defp scored_pixels(%{scorer: :crop, tiles: tiles}, output_px) when is_integer(tiles),
    do: min(output_px, tiles * @tile_px / 1_000)

  defp scored_pixels(_aq, output_px), do: output_px
end

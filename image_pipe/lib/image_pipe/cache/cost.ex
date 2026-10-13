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
  #   decode    source pixels × the source format's weight. Shrink-on-load
  #             saves less than its scale, so source pixels predict it better
  #             than decoded ones. An SVG renders at its decoded size.
  #   pixels    decoded pixels, for the resize and conversions on them
  #   alpha     decoded pixels again when the source has an alpha channel
  #   encode    output pixels × the encoder's weight at its effort
  #   search    each autoquality iteration encodes again, decodes the
  #             candidate and scores it (all pixels, or 512 × 512 tiles for
  #             the crop scorer)
  #   detect    one per group whose crop runs a detector
  #
  # A placeholder or info response is one constant per kind. Pixel amounts
  # are in thousands, so a pixel weight is in milliseconds per megapixel. The
  # weights come from `bench/cost_calibration.exs`. Efforts it doesn't
  # measure are interpolated. A baseline JPEG decodes much faster with
  # shrink-on-load than a progressive one, which the debug info doesn't tell
  # apart, so a large baseline source is overestimated.
  @moduledoc false

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Resolved

  @weights %{
    :request => 3_900,
    :pixels => 0.7,
    :alpha => 10,
    :metric => 4,
    :detect => 150_000,
    {:decode, :jpeg} => 2.6,
    {:decode, :png} => 10,
    {:decode, :webp} => 1.9,
    {:decode, :avif} => 9.4,
    {:decode, :heif} => 9.4,
    {:decode, :jpeg_xl} => 8,
    {:decode, :jpeg2000} => 30,
    {:decode, :tiff} => 2.6,
    {:decode, :gif} => 4.5,
    {:decode, :svg} => 20,
    {:encode, :jpeg} => 2.1,
    {:encode, :png} => 64,
    {:encode, :png_palette} => 110,
    {:encode, :webp, 0} => 18,
    {:encode, :webp, 1} => 23,
    {:encode, :webp, 2} => 28,
    {:encode, :webp, 3} => 40,
    {:encode, :webp, 4} => 56,
    {:encode, :webp, 5} => 74,
    {:encode, :webp, 6} => 96,
    {:encode, :avif, 0} => 9.8,
    {:encode, :avif, 1} => 18,
    {:encode, :avif, 2} => 33,
    {:encode, :avif, 3} => 43,
    {:encode, :avif, 4} => 200,
    {:encode, :avif, 5} => 320,
    {:encode, :avif, 6} => 590,
    {:encode, :avif, 7} => 770,
    {:encode, :avif, 8} => 1_000,
    {:encode, :avif, 9} => 1_300,
    {:terminal, :info} => 1_800,
    {:terminal, :blurhash} => 7_600,
    {:terminal, :lqip_css} => 11_000
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
      {:pixels, decoded_kpx},
      {:alpha, if(info.source_alpha?, do: decoded_kpx, else: 0)},
      {decode_feature(info.source_format), decode_kpx(info, decoded_kpx)},
      {encoder(output.format, output.encoder_options), output_kpx * (1 + iterations)},
      {decode_feature(output.format), output_kpx * iterations},
      {:metric, scored_kpx(info.aq, output_kpx) * iterations},
      {:detect, info.detections}
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

  defp decode_kpx(%Info{source_format: :svg}, decoded_kpx), do: decoded_kpx
  defp decode_kpx(%Info{} = info, _decoded_kpx), do: kpx(info.source_width, info.source_height)

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

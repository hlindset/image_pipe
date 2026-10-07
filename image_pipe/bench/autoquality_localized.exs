# From image_pipe/: mise exec -- mix run --no-compile
# bench/autoquality_localized.exs OUTPUT.jsonl DETAILS_DIRECTORY
# Synthetic native-resolution details are placed inside and outside sampled tiles.
# Region scores expose context sensitivity; they are not human quality judgments.
Code.require_file("support/autoquality_research.exs", __DIR__)

defmodule AutoqualityLocalized do
  alias AutoqualityResearch, as: Bench
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @width 3072
  @height 2604

  def main([output, details]) do
    Bench.configure()
    File.write!(output, "")
    File.mkdir_p!(details)
    coords = CropScore.sample_tiles(@width, @height)
    [{sx, sy, _, _} | _] = coords
    inside = {sx + 128, sy + 128}
    outside = find_outside(coords)

    Bench.emit(
      output,
      Map.merge(Bench.environment(), %{
        experiment: :localized,
        dimensions: [@width, @height],
        locations: Enum.map(coords, &Tuple.to_list/1),
        inside: Tuple.to_list(inside),
        outside: Tuple.to_list(outside)
      })
    )

    for kind <- [:text, :colored_edges, :gradient, :mixed],
        {placement, {x, y}} <- [inside: inside, outside: outside] do
      {:ok, svg} = Image.from_svg(svg(kind))
      {:ok, patch} = Image.flatten(svg, background: [255, 255, 255])

      {:ok, embedded} =
        Operation.embed(patch, x, y, @width, @height,
          extend: :VIPS_EXTEND_BACKGROUND,
          background: [255, 255, 255]
        )

      {:ok, base} = VipsImage.copy_memory(embedded)
      {:ok, _} = Image.write(patch, Path.join(details, "#{kind}-reference.png"))

      for format <- [:jpeg, :webp, :avif] do
        {:ok, body, meta} = EncodeSearch.run(base, Bench.policy(format), scorer: :crop)
        {:ok, candidate} = Image.from_binary(body)
        {:ok, region} = Image.crop(candidate, x, y, 256, 256)
        {:ok, region_body} = Image.write(region, :memory, suffix: ".png")
        {:ok, reference_body} = Image.write(patch, :memory, suffix: ".png")
        File.write!(Path.join(details, "#{kind}-#{placement}-#{format}.png"), region_body)
        region_score = Bench.truth(patch, region_body)
        {:ok, window} = Image.crop(base, max(0, x - 128), max(0, y - 128), 512, 512)

        {:ok, candidate_window} =
          Image.crop(candidate, max(0, x - 128), max(0, y - 128), 512, 512)

        {:ok, window_body} = Image.write(candidate_window, :memory, suffix: ".png")

        Bench.emit(output, %{
          kind: :sample,
          content: kind,
          placement: placement,
          format: format,
          meta: meta,
          body: Bench.body_summary(body),
          full_truth: Bench.truth(base, body),
          region_truth: region_score,
          window_truth: Bench.truth(window, window_body),
          region_pixels_equal: Bench.pixels(region_body) == Bench.pixels(reference_body)
        })
      end

      IO.puts("localized: #{kind} #{placement}")
    end
  end

  defp find_outside(samples) do
    CropScore.tile_coords(@width, @height)
    |> Enum.map(fn {x, y, _, _} -> {x + 128, y + 128} end)
    |> Enum.find(fn {x, y} ->
      Enum.all?(samples, fn {sx, sy, sw, sh} ->
        x + 256 <= sx or sx + sw <= x or y + 256 <= sy or sy + sh <= y
      end)
    end)
  end

  defp svg(kind) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="256" height="256">
    <defs><linearGradient id="g"><stop stop-color="#728295"/><stop offset="1" stop-color="#a8b6c2"/></linearGradient></defs>
    <rect width="256" height="256" fill="white"/>
    #{content(kind)}
    </svg>
    """
  end

  defp content(:text), do: text("#202020", 0)

  defp content(:colored_edges) do
    [
      text("#c00040", 0),
      for(y <- 4..12, do: "<path d='M4 #{y * 19} H251' stroke='#0040c0' stroke-width='1'/>")
    ]
    |> IO.iodata_to_binary()
  end

  defp content(:gradient), do: "<rect x='4' y='4' width='248' height='248' fill='url(#g)'/>"

  defp content(:mixed),
    do: "<rect x='4' y='4' width='248' height='124' fill='url(#g)'/>" <> text("#402060", 96)

  defp text(color, offset) do
    for line <- 0..9, into: "" do
      "<text x='5' y='#{15 + offset + line * 14}' font-family='monospace' font-size='11' fill='#{color}'>#{line}: cache_key = x + 0.125</text>"
    end
  end
end

AutoqualityLocalized.main(System.argv())

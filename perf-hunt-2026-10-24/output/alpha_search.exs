alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
alias ImagePipe.Output.{EncodeSearch, Resolved}
alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
alias ImagePipe.Plan.Output.{AvifOptions, WebpOptions}

cpu = fn ->
  [_, rest] = File.read!("/proc/self/stat") |> String.split(") ", parts: 2)
  f = String.split(rest, " ")
  (String.to_integer(Enum.at(f, 11)) + String.to_integer(Enum.at(f, 12))) * 10
end

res = fn fmt, eo, rails, sq ->
  {lo, hi} = rails

  %Resolved{
    format: fmt,
    quality: :default,
    response_headers: [],
    strip_metadata: true,
    keep_copyright: false,
    color_profile: :preserve_source,
    encoder_options: eo,
    quality_search: %RQS.Ssimulacra2{target: 75, min_quality: lo, max_quality: hi, start_quality: sq, allowed_error: 0.5}
  }
end

{:ok, rgb} = Op.thumbnail("priv/static/images/dog.jpg", 1600)
{:ok, rgb} = V.copy_memory(rgb)
{:ok, rgba} = Op.bandjoin_const(rgb, [255.0])
{:ok, rgba} = V.copy_memory(rgba)

for {fl, r} <- [
      {"avif", res.(:avif, %AvifOptions{effort: 3, subsample_mode: :off}, {20, 90}, 53)},
      {"webp", res.(:webp, %WebpOptions{effort: 4}, {25, 95}, 78)}
    ] do
  acc =
    for _ <- 1..3, {n, img} <- Enum.shuffle(rgb: rgb, rgba: rgba), reduce: %{} do
      acc ->
        c0 = cpu.()
        {us, {:ok, bin, meta}} = :timer.tc(fn -> EncodeSearch.run(img, r, scorer: :full) end)
        c = cpu.() - c0
        row = {us / 1000, c, byte_size(bin), meta.quality}
        Map.update(acc, n, [row], &[row | &1])
    end

  for n <- [:rgb, :rgba] do
    l = acc[n]
    IO.puts("#{fl} #{n}: wall ms #{inspect(Enum.map(l, &round(elem(&1, 0))))} cpu ms #{inspect(Enum.map(l, &elem(&1, 1)))} bytes #{elem(hd(l), 2)} q #{elem(hd(l), 3)}")
  end
end

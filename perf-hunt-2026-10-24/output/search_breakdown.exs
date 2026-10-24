alias Vix.Vips.Image, as: V
alias Vix.Vips.Operation, as: Op
alias ImagePipe.Output.{EncodeSearch, Resolved}
alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, WebpOptions}

prefix = [:aqbench]
table = :ets.new(:legs, [:public, :bag])

legs = [
  [:encode, :search, :probe, :encode],
  [:encode, :search, :probe, :ssimulacra2, :decode],
  [:encode, :search, :probe, :ssimulacra2, :metric],
  [:encode, :search]
]

:telemetry.attach_many(
  "aq",
  Enum.map(legs, &(prefix ++ &1 ++ [:stop])),
  fn event, %{duration: d}, _meta, _ ->
    :ets.insert(table, {Enum.drop(event, 1) |> Enum.drop(-1), System.convert_time_unit(d, :native, :microsecond)})
  end,
  nil
)

start_q = %{jpeg: 76, webp: 78, avif: 53}
rails = %{jpeg: {25, 95}, webp: {25, 95}, avif: {20, 90}}
opts = %{jpeg: %JpegOptions{}, webp: %WebpOptions{effort: 4}, avif: %AvifOptions{effort: 3, subsample_mode: :off}}

resolved = fn fmt ->
  {lo, hi} = rails[fmt]

  %Resolved{
    format: fmt,
    quality: :default,
    response_headers: [],
    strip_metadata: true,
    keep_copyright: false,
    color_profile: :preserve_source,
    encoder_options: opts[fmt],
    quality_search: %RQS.Ssimulacra2{target: 75, min_quality: lo, max_quality: hi, start_quality: start_q[fmt], allowed_error: 0.5}
  }
end

[path, w | fmts] = System.argv()
{:ok, img} = Op.thumbnail(path, String.to_integer(w), height: 100_000)
{:ok, img} = V.copy_memory(img)
mp = V.width(img) * V.height(img) / 1.0e6
scorer = if mp > 6, do: :crop, else: :full

for fmt <- Enum.map(fmts, &String.to_atom/1) do
  :ets.delete_all_objects(table)
  {us, {:ok, bin, meta}} = :timer.tc(fn -> EncodeSearch.run(img, resolved.(fmt), scorer: scorer, telemetry_opts: [telemetry_prefix: prefix]) end)
  sum = fn leg -> :ets.lookup(table, leg) |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel./(1000) end
  n = fn leg -> length(:ets.lookup(table, leg)) end

  IO.puts(
    :io_lib.format(
      "~s ~.1fMP ~-5s ~-4s total ~7.1f ms | encode ~6.1f ms (~p) | decode ~6.1f ms (~p) | metric ~6.1f ms (~p) | other ~5.1f | q=~p iters=~p bytes=~p score=~.2f",
      [Path.basename(path), mp, fmt, scorer, us / 1000, sum.([:encode, :search, :probe, :encode]), n.([:encode, :search, :probe, :encode]),
       sum.([:encode, :search, :probe, :ssimulacra2, :decode]), n.([:encode, :search, :probe, :ssimulacra2, :decode]),
       sum.([:encode, :search, :probe, :ssimulacra2, :metric]), n.([:encode, :search, :probe, :ssimulacra2, :metric]),
       us / 1000 - sum.([:encode, :search, :probe, :encode]) - sum.([:encode, :search, :probe, :ssimulacra2, :decode]) - sum.([:encode, :search, :probe, :ssimulacra2, :metric]),
       meta.quality, meta.iterations, byte_size(bin), meta.score]
    )
  )
end

alias ImagePipe.API.{Parser, Path}
alias ImagePipe.Plan
alias ImagePipe.URL, as: U
tiny = [5.0e-324, 1.0e-300, 1.0e-7, 0.1 + 0.2, 1/3, 2.0e-6, 0.000001, 0.9999999999999999, 1.0e15 + 0.5, 4503599627370495.5, 9007199254740991.0, 9007199254740992.0, 2147483647.0, 2147483646.9999998, 1.0e20, 1.7976931348623157e308]
nums = tiny ++ Enum.map(tiny, &(-&1)) ++ [0, 0.0, -0.0, 1, 2147483647, 2147483648, -2147483647]
cover = [resize: [width: 100, height: 100, fit: :cover]]
cases =
  (for v <- nums, do: {"rotate #{v}", [rotate: v]}) ++
  (for v <- nums, do: {"dpr #{v}", [resize: [width: 10], dpr: v]}) ++
  (for v <- nums, do: {"zoom #{v}", [resize: [width: 10, zoom: v]]}) ++
  (for v <- nums, do: {"zoom2 #{v}", [resize: [width: 10, zoom: {v, 2}]]}) ++
  (for v <- nums, do: {"crop #{v}", [crop: {v, 10}]}) ++
  (for v <- nums, do: {"croppct #{v}", [crop: {{:pct, v}, 10}]}) ++
  (for v <- nums, do: {"region #{v}", [region: {v, v, 10, {:pct, v}}]}) ++
  (for v <- nums, do: {"aoff #{v}", cover ++ [anchor: :top, anchor_offset: {v, {:pct, v}}]}) ++
  (for v <- nums, do: {"blur #{v}", [blur: v]}) ++
  (for v <- nums, do: {"sharpen #{v}", [sharpen: v]}) ++
  (for v <- nums, do: {"contrast #{v}", [contrast: v]}) ++
  (for v <- nums, do: {"sat #{v}", [saturation: v]}) ++
  (for v <- nums, do: {"focus #{v}", cover ++ [focus: {v, 0.5}]}) ++
  (for v <- nums, do: {"detect #{v}", cover ++ [detect: [{"face", v}, :all]]}) ++
  (for v <- nums, do: {"detect2 #{v}", cover ++ [detect: [{:all, v}, {"face", 1}]]}) ++
  (for v <- nums, do: {"trim #{v}", [trim: {"fff", v}]}) ++
  (for v <- nums, do: {"bg #{v}", [padding: 1, background: {"fff", v}]}) ++
  (for v <- nums, do: {"grad #{v}", [gradient: [opacity: 0.5, color: "red", direction: v, start: 0.1, stop: 0.9]]}) ++
  (for v <- nums, do: {"grad op #{v}", [gradient: [opacity: v, color: "red"]]}) ++
  (for v <- nums, do: {"pblur #{v}", [progressive_blur: [sigma: v, direction: v]]}) ++
  (for v <- nums, do: {"mono #{v}", [monochrome: [intensity: v]]}) ++
  (for v <- nums, do: {"colorize #{v}", [colorize: [opacity: v, color: "red", keep_alpha: true]]}) ++
  (for v <- nums, do: {"wm opacity #{v}", [watermark: :logo, watermark_opacity: v, watermark_scale: v]}) ++
  (for v <- nums, do: {"wm off #{v}", [watermark: :logo, watermark_offset: {v, v}, watermark_tile: true, watermark_gap: {v, {:pct, v}}]}) ++
  (for v <- nums, do: {"extend off #{v}", [resize: [width: 10, height: 10], extend: true, extend_offset: {v, v}]}) ++
  (for v <- [1, 2147483647, {2147483647, 1}, {4294967294, 2}, {3, 6}], do: {"ratio #{inspect v}", [crop: {10,10}, crop_ratio: (if is_tuple(v), do: v, else: {v, 1})]})
mismatch = Enum.reduce(cases, 0, fn {label, opts}, acc ->
  try do
    b = U.new() |> U.group(opts)
    built = Plan.to_spec(b.plan)
    parsed =
      case U.url(b, "a.jpg") do
        {:ok, url} ->
          {:ok, lexed} = Path.extract(url, "")
          {url, Parser.parse(lexed, presets: %{})}
        e -> {nil, e}
      end
    {url, p} = parsed
    norm = fn {:ok, s} -> {:ok, %{s | ignored: []}}; {:error, _} -> :error; o -> o end
    if (case {built, p} do {{:ok, a}, {:ok, b2}} -> :erlang.term_to_binary(%{a | ignored: []}) == :erlang.term_to_binary(%{b2 | ignored: []}); {{:error,_},{:error,_}} -> true; _ -> false end) do
      acc
    else
      IO.puts("MISMATCH #{label}: url=#{inspect url}\n  built=#{inspect(norm.(built), limit: :infinity) |> String.slice(0, 1500)}\n  parsed=#{inspect(p, limit: 30) |> String.slice(0, 1500)}")
      acc + 1
    end
  rescue e -> IO.puts("RAISE #{label}: #{Exception.message(e) |> String.slice(0, 300)}"); acc + 1
  end
end)
IO.puts("mismatches #{mismatch} of #{length(cases)}")

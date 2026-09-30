# Decode-mode benchmark over an image corpus: streaming (new_from_enum, the pre-Plan-A
# path) vs buffered (new_from_buffer, the Plan-A path), for a decode -> downscale -> encode
# workload. Iterates every image in a corpus so results span format, size, and dimensions.
#
# Run with mise so tool versions match:
#
#   # default: both modes over priv/static/images, sequential access, 400px target
#   mise exec -- mix run bench/decode_modes.exs
#
#   # one mode per OS process -> cleanest, isolated peak-RSS reading:
#   mise exec -- mix run bench/decode_modes.exs streaming
#   mise exec -- mix run bench/decode_modes.exs buffered
#
# Positional args: <mode> <access> <corpus> <width> <iters>   (plus optional --leak flag)
#   mode   : streaming | buffered | both   (default: both)
#   access : sequential | random           (default: sequential)
#   corpus : a directory, a glob, or a single file   (default: priv/static/images)
#   width  : target downscale width in px            (default: 400)
#   iters  : timed iterations per image (1 warmup discarded)  (default: 5)
#   --leak : turn on libvips leak checking and call vips_shutdown at the end, which prints a
#            "memory: high-water mark N MB" line — the real libvips working-set peak. This is
#            the reliable libvips memory signal here; the high-water is process-wide, so use
#            one mode + one file for a clean per-case figure:
#              mise exec -- mix run bench/decode_modes.exs buffered sequential priv/static/images/waterfall.jpg 400 5 --leak
#   --csv  : emit one machine-readable CSV row per (file, mode) to stdout and suppress the
#            human tables (consumed by the bench/decode_matrix.exs orchestrator). No header
#            row is printed. Columns:
#              file,fmt,megapixels,mode,access,width,iters,median_ms,min_ms,max_ms,libvips_peak_bytes,rss_peak_bytes,out_w,out_h
#            libvips_peak_bytes (tracked_get_mem_highwater) and rss_peak_bytes are both reliable.
#            The high-water is process-wide and non-resettable, so clean per-file memory requires
#            one file + one mode per process (what the orchestrator does). Mutually exclusive
#            with --leak.
#
# MEMORY NOTES:
#   * Peak RSS is OS-sampled (`ps -o rss`) across each mode's whole corpus run, so it
#     includes libvips off-heap allocations. In `both` mode the second mode's peak is
#     floored by RSS the first left resident (the OS allocator does not return it), so for
#     a clean per-mode peak run a single mode per process. The streaming vs buffered gap is
#     largest under `random` access (the streaming pipe cannot seek, forcing libvips to
#     materialize the whole decoded image).
#   * Vix.Vips.tracked_get_mem_highwater/0 gives the libvips working-set peak programmatically
#     (emitted as libvips_peak_bytes under --csv). It is process-wide, monotonic, and
#     non-resettable, so it is a clean per-case figure only with one mode + one file per process.
#     Requires a Vix that fixed the high-water NIF registration; older Vix returned current
#     tracked memory (~0 after frees).
#   * --leak is an alternative human-readable libvips peak via vips_shutdown (terminal; see flag).
#   * The libvips operation cache is disabled below to remove cross-iteration noise.

defmodule DecodeBench do
  @default_corpus "priv/static/images"
  @exts ~w(.jpg .jpeg .png .webp .gif .tif .tiff .avif)
  @sample_interval_ms 10

  def main(argv) do
    {csv?, argv} = pop_flag(argv, "--csv")
    {leak_flag?, argv} = pop_flag(argv, "--leak")
    # --csv produces pure CSV on stdout, so leak's human shutdown report must not run.
    leak? = not csv? and (leak_flag? or System.get_env("VIPS_LEAK") == "1")

    # libvips only emits its "memory: high-water mark" line from vips_shutdown(), and only when
    # leak checking is on. Vix never calls vips_shutdown automatically, so --leak turns leak
    # checking on, runs the workload, then calls shutdown at the very end to flush the figure.
    # This is the true libvips working-set peak (build-portable), unlike Vix's
    # tracked_get_mem_highwater/0 (see notes below).
    if leak?, do: Vix.Vips.set_vips_leak_checking(true)
    run(argv, leak?, csv?)
    if leak?, do: flush_leak_report()
  end

  defp run(argv, leak?, csv?) do
    {mode, access, corpus, width, iters} = parse(argv)
    files = resolve_corpus(corpus)

    if files == [] do
      IO.puts(:stderr, "no images found in corpus: #{corpus}")
      System.halt(1)
    end

    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)

    raw_opts = [access: access, fail_on: :error]
    {:ok, validated_opts} = Image.Options.Open.validate_options(raw_opts)

    unless csv? do
      IO.puts("""
      decode-mode benchmark
        corpus:    #{corpus} (#{length(files)} images)
        access:    #{access}
        width:     #{width}px target
        iters:     #{iters} per image (+1 warmup discarded)
        vips_leak: #{leak_status(leak?)}
      """)
    end

    modes = if mode == :both, do: [:streaming, :buffered], else: [mode]

    mode_data =
      Map.new(modes, fn m ->
        {rows, rss} = run_mode(m, files, raw_opts, validated_opts, width, iters)
        {m, %{rows: rows, rss: rss, vips_hw: Vix.Vips.tracked_get_mem_highwater()}}
      end)

    if csv? do
      emit_csv(modes, files, mode_data, access, width, iters)
    else
      report(
        modes,
        files,
        Map.new(mode_data, fn {m, d} -> {m, d.rows} end),
        Map.new(mode_data, fn {m, d} -> {m, d.rss} end)
      )
    end
  end

  defp run_mode(mode, files, raw_opts, validated_opts, width, iters) do
    decode = fn path -> decoder(mode, path, raw_opts, validated_opts) end
    sampler = start_rss_sampler()

    rows =
      Map.new(files, fn path ->
        {path, measure_file(decode.(path), width, iters)}
      end)

    {rows, stop_rss_sampler(sampler)}
  end

  # Returns %{src: {w,h}, out: {w,h}, median_us: n} | %{error: reason}.
  defp measure_file(decode, width, iters) do
    case decode.() do
      {:ok, warm} ->
        src = {Vix.Vips.Image.width(warm), Vix.Vips.Image.height(warm)}
        :erlang.garbage_collect()

        {durations, out} =
          Enum.reduce(1..iters, {[], nil}, fn _, {acc, _} ->
            t0 = :erlang.monotonic_time(:microsecond)
            out = decode_resize_encode(decode, width)
            t1 = :erlang.monotonic_time(:microsecond)
            {[t1 - t0 | acc], out}
          end)

        %{
          src: src,
          out: out,
          median_us: median(durations),
          min_us: Enum.min(durations),
          max_us: Enum.max(durations)
        }

      {:error, reason} ->
        %{error: reason}
    end
  rescue
    e -> %{error: Exception.message(e)}
  end

  # Force the full decode -> resize -> encode pipeline (libvips is lazy).
  defp decode_resize_encode(decode, width) do
    {:ok, image} = decode.()
    scale = width / Vix.Vips.Image.width(image)
    {:ok, resized} = Image.resize(image, scale)
    _ = Image.write!(resized, :memory, suffix: ".jpg")
    {Vix.Vips.Image.width(resized), Vix.Vips.Image.height(resized)}
  end

  defp pop_flag(argv, flag), do: {flag in argv, Enum.reject(argv, &(&1 == flag))}

  # Flush libvips' "memory: high-water mark" line by shutting libvips down (terminal — no
  # libvips use after this). Counter is process-wide, so it's the peak across the whole run.
  defp flush_leak_report do
    :erlang.garbage_collect()

    IO.puts(
      "\nlibvips memory high-water (process-wide peak; run one mode + one file for a clean per-case figure).\n" <>
        "Any 'VipsArea alive' lines are live BEAM-held image refs awaiting GC, not leaks; the useful line is 'memory: high-water mark':"
    )

    Vix.Nif.nif_vips_shutdown()
  end

  defp leak_status(true),
    do: "on — prints libvips 'memory: high-water mark' at end (process-wide peak)"

  defp leak_status(false), do: "off — pass --leak for the libvips working-set peak"

  defp decoder(:streaming, path, raw_opts, _validated),
    do: fn -> Image.open(File.stream!(path, 65_536, []), raw_opts) end

  defp decoder(:buffered, path, _raw, validated_opts),
    do: fn -> Vix.Vips.Image.new_from_buffer(File.read!(path), validated_opts) end

  # --- reporting ---

  defp report([single], files, results, peaks) do
    rows = Map.fetch!(results, single)

    IO.puts(
      String.pad_trailing("file", 26) <>
        col("fmt") <> col("megapixels") <> col("out") <> col("#{single} ms")
    )

    Enum.each(files, fn path ->
      r = Map.fetch!(rows, path)
      IO.puts(label(path) <> col(fmt(path)) <> col(mp(r)) <> col(out(r)) <> col(time_cell(r)))
    end)

    IO.puts("\npeak RSS [#{single}]: #{fmt_bytes(Map.fetch!(peaks, single))}\n#{rss_caveat()}")
  end

  defp report([:streaming, :buffered], files, results, peaks) do
    s = Map.fetch!(results, :streaming)
    b = Map.fetch!(results, :buffered)

    IO.puts(
      String.pad_trailing("file", 26) <>
        col("fmt") <>
        col("megapixels") <> col("streaming ms") <> col("buffered ms") <> col("buffered/strm")
    )

    Enum.each(files, fn path ->
      rs = Map.fetch!(s, path)
      rb = Map.fetch!(b, path)

      IO.puts(
        label(path) <>
          col(fmt(path)) <>
          col(mp(rs)) <> col(time_cell(rs)) <> col(time_cell(rb)) <> col(ratio(rs, rb))
      )
    end)

    IO.puts("""

    peak RSS:  streaming #{fmt_bytes(Map.fetch!(peaks, :streaming))}   buffered #{fmt_bytes(Map.fetch!(peaks, :buffered))}
    #{rss_caveat()}
    """)
  end

  # --- machine-readable output (for bench/decode_matrix.exs) ---

  defp emit_csv(modes, files, mode_data, access, width, iters) do
    for m <- modes, path <- files do
      d = Map.fetch!(mode_data, m)
      IO.puts(csv_row(path, m, access, width, iters, Map.fetch!(d.rows, path), d.rss, d.vips_hw))
    end
  end

  defp csv_row(path, mode, access, width, iters, %{error: _}, rss, vips_hw) do
    csv([
      path,
      fmt(path),
      "",
      mode,
      access,
      width,
      iters,
      "ERR",
      "ERR",
      "ERR",
      vips_hw,
      rss,
      "",
      ""
    ])
  end

  defp csv_row(path, mode, access, width, iters, r, rss, vips_hw) do
    {sw, sh} = r.src
    {ow, oh} = r.out

    csv([
      path,
      fmt(path),
      :erlang.float_to_binary(sw * sh / 1_000_000, decimals: 2),
      mode,
      access,
      width,
      iters,
      ms(r.median_us),
      ms(r.min_us),
      ms(r.max_us),
      vips_hw,
      rss,
      ow,
      oh
    ])
  end

  defp csv(fields), do: fields |> Enum.map_join(",", &to_string/1)

  defp label(path), do: String.pad_trailing(Path.basename(path), 26)
  defp col(v), do: String.pad_trailing(to_string(v), 16)
  defp fmt(path), do: path |> Path.extname() |> String.trim_leading(".")

  defp mp(%{src: {w, h}}), do: :erlang.float_to_binary(w * h / 1_000_000, decimals: 1)
  defp mp(_), do: "-"
  defp out(%{out: {w, h}}), do: "#{w}x#{h}"
  defp out(_), do: "-"
  defp time_cell(%{median_us: us}), do: ms(us)
  defp time_cell(%{error: _}), do: "ERR"

  defp ratio(%{median_us: a}, %{median_us: b}) when a > 0,
    do: "#{:erlang.float_to_binary(b / a, decimals: 2)}x"

  defp ratio(_, _), do: "-"

  defp rss_caveat,
    do:
      "(RSS is whole-process and inflated by allocator retention; treat as directional. " <>
        "Run a single mode per process for a clean per-mode peak.)"

  # --- peak RSS sampling ---

  defp start_rss_sampler, do: spawn(fn -> sample_loop(read_rss_bytes()) end)

  defp stop_rss_sampler(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:rss_peak, peak} -> peak
    after
      5_000 -> 0
    end
  end

  defp sample_loop(peak) do
    receive do
      {:stop, from} -> send(from, {:rss_peak, peak})
    after
      @sample_interval_ms -> sample_loop(max(peak, read_rss_bytes()))
    end
  end

  defp read_rss_bytes do
    case :os.cmd(~c"ps -o rss= -p #{System.pid()}") do
      ~c"" ->
        0

      chars ->
        chars |> to_string() |> String.trim() |> Integer.parse() |> rss_kb()
    end
  end

  defp rss_kb({kb, _}), do: kb * 1024
  defp rss_kb(:error), do: 0

  # --- arg parsing + corpus + small helpers ---

  defp parse(argv) do
    mode = argv |> Enum.at(0, "both") |> to_mode()
    access = argv |> Enum.at(1, "sequential") |> to_access()
    corpus = Enum.at(argv, 2, @default_corpus)
    width = argv |> Enum.at(3, "400") |> String.to_integer()
    iters = argv |> Enum.at(4, "5") |> String.to_integer()
    {mode, access, corpus, width, iters}
  end

  defp resolve_corpus(corpus) do
    cond do
      File.dir?(corpus) -> Path.wildcard(Path.join(corpus, "*"))
      File.regular?(corpus) -> [corpus]
      true -> Path.wildcard(corpus)
    end
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in @exts))
    |> Enum.sort_by(&File.stat!(&1).size)
  end

  defp to_mode("streaming"), do: :streaming
  defp to_mode("buffered"), do: :buffered
  defp to_mode("both"), do: :both

  defp to_mode(o),
    do: raise(ArgumentError, "mode must be streaming|buffered|both, got #{inspect(o)}")

  defp to_access("sequential"), do: :sequential
  defp to_access("random"), do: :random

  defp to_access(o),
    do: raise(ArgumentError, "access must be sequential|random, got #{inspect(o)}")

  defp median([]), do: 0

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)

  defp fmt_bytes(b) when b >= 1_048_576,
    do: "#{:erlang.float_to_binary(b / 1_048_576, decimals: 1)} MiB"

  defp fmt_bytes(b) when b >= 1024, do: "#{:erlang.float_to_binary(b / 1024, decimals: 1)} KiB"
  defp fmt_bytes(b), do: "#{b} B"
end

DecodeBench.main(System.argv())

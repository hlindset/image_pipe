defmodule Mix.Tasks.Autoquality.Bench do
  @shortdoc "Benchmark the autoquality ssim2 encode-quality search — cost curve + accuracy (no Docker)"
  @moduledoc """
  Produces real performance + accuracy numbers for the autoquality / max_bytes
  encode-quality search (`ImagePipe.Output.EncodeSearch`, shipped in #351). The
  search runs at the output/encode boundary; for the `:ssim2` objective every
  iteration does a full-resolution **encode + decode + SSIMULACRA2 metric** on
  the result, and the metric dominates. This task quantifies that.

  Gated off the default `mix test` lane: it lives under `test/support/mix/tasks`
  (compiled only in `MIX_ENV=test`), is a Mix task (never a test the lane runs),
  is NIF-heavy (the `ssimulacra2` Rust NIF) and slow. Auto-selects `MIX_ENV=test`
  via `mix.exs` `preferred_envs`.

      mise exec -- mix autoquality.bench                 # parts A+B, default sizes
      mise exec -- mix autoquality.bench --part a        # cost curve only
      mise exec -- mix autoquality.bench --part b        # accuracy/behavior only
      mise exec -- mix autoquality.bench --part c        # proxy-seed method + accuracy
      mise exec -- mix autoquality.bench --part all      # A + B + C
      mise exec -- mix autoquality.bench --mps 1,4,9     # custom Part A megapixels
      mise exec -- mix autoquality.bench --proxy-factors 2,4 --proxy-mp 25  # Part C knobs
      mise exec -- mix autoquality.bench --csv           # also write CSVs under /tmp

  ## Part A — per-megapixel cost curve

  Runs the real `:ssim2` search (target #{88}, bracket [#{40},#{95}],
  max_iterations #{6}) on a deterministic high-frequency zone-plate at a range of
  output sizes (default ~1, 4, 9, 16, 25, 36 MP). The zone-plate is adversarial
  for JPEG, so the search uses its full iteration budget — worst-case cost. The
  encode / decode / metric phases are wrapped (injected `encode_fun`/`score_fun`
  over `Encoder.encode_to_buffer` + `Ssim2Metric`) and timed separately, so the
  table shows where the wall-clock goes as a function of pixel count. This is the
  data that sets a sane `autoquality_max_resolution` default.

  ## Part B — accuracy + behavior over real content

  Runs the production encode path (`Encoder.stream_output/3`, which finalizes the
  image exactly as a real request would) over the committed differential sources
  at their native sizes, for three configurations on each source:

    * `ssim2:#{88}:#{40}:#{95}` — records chosen quality, the achieved
      SSIMULACRA2 score vs the target (the search's own `final_score` telemetry,
      not an ad-hoc baseline), bytes vs a fixed `q90` baseline (savings %), and
      iteration count.
    * `size` and `max_bytes` to the same byte budget — these skip the
      decode+metric, so they are far cheaper; the table quantifies the gap.

  Goal: confirm `:ssim2` lands at/above its target, and surface typical quality /
  savings / iteration counts to validate (or adjust) the shipped defaults.

  ## Part C — downscaled-proxy-seed method + accuracy

  Explores the deferred optimization: instead of searching at full resolution,
  downscale by `1/k`, run the ssim2 search on the proxy to pick a quality, then
  encode the **full-res** image once at that quality. For each subject × factor it
  records the full-res search as ground truth (`q_full`), the proxy's pick
  (`q_proxy`), and — the real accuracy question — the **delivered** full-res
  SSIMULACRA2 score of the full-res encode at `q_proxy`, plus byte movement and the
  measured speedup. Subjects: the committed sRGB high-detail sources at native size
  plus an adversarial zone-plate at `--proxy-mp` (default 16). The error is
  two-directional (real content over-picks quality → byte overshoot; the
  adversarial chirp under-picks → undershoot), so the findings weigh a modest `k`
  against a confirm-and-adjust step rather than a fixed margin.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric
  alias ImagePipe.Test.ImgproxyDifferential.SourceInventory
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @prefix [:autoquality_bench]

  # Shipped defaults under test (see ImagePipe.Output.EncodeSearch + the imgproxy
  # autoquality parser).
  @target 88
  @min_q 40
  @max_q 95
  @max_iter 6

  @default_mps [1, 4, 9, 16, 25, 36]
  @baseline_quality 90

  # Part C subjects: the committed sRGB high-detail sources (the ones with real
  # savings in Part B), where the downscale-proxy quality-transfer relationship is
  # meaningful. CMYK / embedded-ICC / 16-bit / alpha sources are excluded to keep
  # the light finalize (copy_memory + sRGB + flatten) a no-op-equivalent.
  @part_c_sources [
    "high_freq.jpg",
    "marker.png",
    "border.png",
    "border_asym.png",
    "placement.png"
  ]

  @default_factors [2, 3, 4]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          part: :string,
          mps: :string,
          csv: :boolean,
          format: :string,
          proxy_factors: :string,
          proxy_mp: :integer
        ]
      )

    part = Keyword.get(opts, :part, "both")
    csv? = Keyword.get(opts, :csv, false)
    format = opts |> Keyword.get(:format, "jpeg") |> parse_format()
    mps = parse_mps(Keyword.get(opts, :mps))
    factors = parse_factors(Keyword.get(opts, :proxy_factors))
    proxy_mp = Keyword.get(opts, :proxy_mp, 16)

    {:ok, _} = Application.ensure_all_started(:image_pipe)
    warmup(format)

    a_rows = if part in ["a", "both", "all"], do: run_part_a(mps, format), else: nil
    b_rows = if part in ["b", "both", "all"], do: run_part_b(format), else: nil
    c_rows = if part in ["c", "all"], do: run_part_c(factors, proxy_mp, format), else: nil

    if csv? do
      if a_rows, do: write_part_a_csv(a_rows)
      if b_rows, do: write_part_b_csv(b_rows)
      if c_rows, do: write_part_c_csv(c_rows)
    end

    print_findings(a_rows, b_rows, c_rows, format)
  end

  # Touch every NIF/libvips path once so first-call JIT + library init does not
  # land inside a timed measurement (the SSIMULACRA2 NIF's first call is ~10x a
  # warm call). Discarded.
  defp warmup(format) do
    image = zone_plate(256, 256)
    {:ok, ref} = Ssim2Metric.reference(image)
    {:ok, bin} = Encoder.encode_to_buffer(image, ssim2_resolved(format), 80)
    {:ok, candidate} = Image.from_binary(bin)
    {:ok, _} = Ssim2Metric.score(ref, candidate)
    :ok
  end

  # --- Part A: cost curve ---------------------------------------------------

  defp run_part_a(mps, format) do
    IO.puts("\n== Part A — ssim2 search cost vs. megapixels ==")
    IO.puts("objective ssim2  target #{@target}  bracket [#{@min_q},#{@max_q}]  ")
    IO.puts("max_iterations #{@max_iter}  format #{format}  source: deterministic zone-plate\n")

    header =
      pad(["MP", 6]) <>
        pad(["dims", 12]) <>
        pad(["iters", 6]) <>
        pad(["total_ms", 10]) <>
        pad(["ref_ms", 9]) <>
        pad(["encode_ms", 11]) <>
        pad(["decode_ms", 11]) <>
        pad(["metric_ms", 11]) <>
        pad(["/iter_ms", 10]) <>
        pad(["metric%", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    resolved = ssim2_resolved(format)

    rows =
      Enum.map(mps, fn mp ->
        {w, h} = square_dims(mp)
        image = zone_plate(w, h)

        # One-time reference build (part of the real per-request ssim2 cost).
        {ref_us, {:ok, ref}} = timed(fn -> Ssim2Metric.reference(image) end)

        acc = :atomics.new(3, signed: true)
        encode_fun = instrumented_encode(image, resolved, acc)
        score_fun = instrumented_score(ref, acc)

        {search_us, {:ok, _binary, meta}} =
          timed(fn ->
            EncodeSearch.search(resolved.quality_search, nil,
              encode_fun: encode_fun,
              score_fun: score_fun,
              base_quality: @max_q,
              max_iterations: @max_iter,
              telemetry_opts: [telemetry_prefix: @prefix]
            )
          end)

        encode_us = :atomics.get(acc, 1)
        decode_us = :atomics.get(acc, 2)
        metric_us = :atomics.get(acc, 3)
        total_us = ref_us + search_us
        iters = meta.iterations
        per_iter_us = if iters > 0, do: div(encode_us + decode_us + metric_us, iters), else: 0
        metric_pct = pct(metric_us, total_us)

        row = %{
          mp: mp,
          w: w,
          h: h,
          iters: iters,
          total_us: total_us,
          ref_us: ref_us,
          encode_us: encode_us,
          decode_us: decode_us,
          metric_us: metric_us,
          per_iter_us: per_iter_us,
          metric_pct: metric_pct,
          score: meta.score,
          quality: meta.quality
        }

        IO.puts(
          pad([mp, 6]) <>
            pad(["#{w}x#{h}", 12]) <>
            pad([iters, 6]) <>
            pad([ms(total_us), 10]) <>
            pad([ms(ref_us), 9]) <>
            pad([ms(encode_us), 11]) <>
            pad([ms(decode_us), 11]) <>
            pad([ms(metric_us), 11]) <>
            pad([ms(per_iter_us), 10]) <>
            pad(["#{metric_pct}%", 8])
        )

        row
      end)

    rows
  end

  defp instrumented_encode(image, resolved, acc) do
    fn quality ->
      {us, result} = timed(fn -> Encoder.encode_to_buffer(image, resolved, quality) end)
      :atomics.add(acc, 1, us)
      result
    end
  end

  # Mirrors EncodeSearch.run/3's real score closure (decode the candidate buffer,
  # then SSIMULACRA2 against the pre-encode reference) but splits decode vs metric
  # timing. Failures throw the same tagged tuple run/3 catches.
  defp instrumented_score(ref, acc) do
    fn bytes ->
      {dec_us, decoded} = timed(fn -> Image.from_binary(bytes) end)
      :atomics.add(acc, 2, dec_us)
      candidate = unwrap(decoded)

      {met_us, scored} = timed(fn -> Ssim2Metric.score(ref, candidate) end)
      :atomics.add(acc, 3, met_us)
      unwrap(scored)
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: throw({:image_pipe_score_error, reason})

  # --- Part B: accuracy + behavior ------------------------------------------

  defp run_part_b(format) do
    IO.puts("\n== Part B — accuracy + behavior over real sources (native sizes) ==")
    IO.puts("ssim2 target #{@target} [#{@min_q},#{@max_q}]  baseline q#{@baseline_quality}  ")

    IO.puts(
      "format #{format}  size/max_bytes budget = round(q#{@baseline_quality} bytes * 0.6)\n"
    )

    attach_telemetry()

    header =
      pad(["source", 22]) <>
        pad(["dims", 12]) <>
        pad(["MP", 6]) <>
        pad(["q", 4]) <>
        pad(["score", 8]) <>
        pad(["hit?", 6]) <>
        pad(["bytes", 9]) <>
        pad(["q#{@baseline_quality}", 9]) <>
        pad(["save%", 7]) <>
        pad(["iters", 6]) <>
        pad(["ssim2ms", 9]) <>
        pad(["sizems", 8]) <>
        pad(["mbms", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    rows =
      SourceInventory.entries()
      |> Enum.sort_by(&(&1.width * &1.height))
      |> Enum.map(fn entry -> bench_source(entry, format) end)
      |> Enum.reject(&is_nil/1)

    detach_telemetry()
    rows
  end

  defp bench_source(entry, format) do
    path = Path.join(@sources_dir, entry.file)

    case Image.open(path, access: :random) do
      {:ok, image} ->
        mp = Float.round(Image.width(image) * Image.height(image) / 1_000_000, 2)

        # Fixed-quality baseline (no search) — finalized identically.
        {_us, baseline_bytes} = encode_once(image, plain_resolved(format, @baseline_quality))
        budget = round(baseline_bytes * 0.6)

        ssim2 = run_config(image, ssim2_resolved(format))
        size = run_config(image, size_resolved(format, budget))
        mb = run_config(image, max_bytes_resolved(format, budget))

        savings = pct(baseline_bytes - ssim2.bytes, baseline_bytes)
        hit? = ssim2.score && ssim2.score >= @target

        IO.puts(
          pad([entry.file, 22]) <>
            pad(["#{Image.width(image)}x#{Image.height(image)}", 12]) <>
            pad([mp, 6]) <>
            pad([ssim2.quality, 4]) <>
            pad([fmt_score(ssim2.score), 8]) <>
            pad([if(hit?, do: "yes", else: "NO"), 6]) <>
            pad([ssim2.bytes, 9]) <>
            pad([baseline_bytes, 9]) <>
            pad(["#{savings}%", 7]) <>
            pad([ssim2.iters, 6]) <>
            pad([ms(ssim2.us), 9]) <>
            pad([ms(size.us), 8]) <>
            pad([ms(mb.us), 8])
        )

        %{
          source: entry.file,
          w: Image.width(image),
          h: Image.height(image),
          mp: mp,
          quality: ssim2.quality,
          score: ssim2.score,
          hit?: hit?,
          bytes: ssim2.bytes,
          baseline_bytes: baseline_bytes,
          savings: savings,
          iters: ssim2.iters,
          ssim2_us: ssim2.us,
          size_us: size.us,
          size_iters: size.iters,
          mb_us: mb.us,
          mb_iters: mb.iters
        }

      {:error, reason} ->
        IO.puts(pad([entry.file, 22]) <> "skipped (open failed: #{inspect(reason)})")
        nil
    end
  end

  # Run one production search config and read the verdict from the search's own
  # [:encode, :search] :stop telemetry (chosen_quality/bytes/iterations/final_score).
  defp run_config(image, resolved) do
    {us, _result} =
      timed(fn ->
        {:ok, stream, _mime} =
          Encoder.stream_output(image, resolved, telemetry_prefix: @prefix)

        Enum.each(stream, fn _ -> :ok end)
      end)

    meta = receive_search_meta()

    %{
      us: us,
      quality: meta.chosen_quality,
      bytes: meta.chosen_bytes,
      iters: meta.iterations,
      score: Map.get(meta, :final_score)
    }
  end

  defp encode_once(image, resolved) do
    timed(fn ->
      {:ok, stream, _mime} = Encoder.stream_output(image, resolved, [])
      Enum.reduce(stream, 0, fn chunk, acc -> acc + byte_size(chunk) end)
    end)
  end

  # --- Part C: downscaled-proxy-seed method + accuracy ----------------------

  # The proxy method: downscale the finalized image by 1/k, run the ssim2 search
  # on that proxy to pick a quality, then encode the FULL-res image once at that
  # quality. We measure whether the delivered full-res image still hits the target
  # (the real accuracy question) against the current full-res search as ground
  # truth, plus the measured speedup.
  defp run_part_c(factors, synth_mp, format) do
    IO.puts("\n== Part C — downscaled-proxy-seed method + accuracy ==")
    IO.puts("ssim2 target #{@target} [#{@min_q},#{@max_q}]  factors #{inspect(factors)}  ")

    IO.puts(
      "format #{format}  truth = full-res search  delivered = full-res encode at proxy's q\n"
    )

    header =
      pad(["source", 16]) <>
        pad(["MP", 6]) <>
        pad(["k", 3]) <>
        pad(["pMP", 6]) <>
        pad(["qFull", 6]) <>
        pad(["qProxy", 7]) <>
        pad(["dq", 5]) <>
        pad(["fullSc", 8]) <>
        pad(["delivSc", 9]) <>
        pad(["d-#{@target}", 7]) <>
        pad(["hit?", 6]) <>
        pad(["bFull", 9]) <>
        pad(["bProxy", 9]) <>
        pad(["speedup", 8])

    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    resolved = ssim2_resolved(format)

    subjects =
      (@part_c_sources
       |> Enum.map(fn file -> {file, base_image(file)} end)
       |> Enum.reject(fn {_f, img} -> is_nil(img) end)) ++
        [{"zone-#{synth_mp}MP", zone_plate_for(synth_mp)}]

    subjects
    |> Enum.flat_map(fn {label, base} ->
      bench_proxy_subject(label, base, factors, resolved)
    end)
  end

  defp bench_proxy_subject(label, base, factors, resolved) do
    mp = Float.round(Image.width(base) * Image.height(base) / 1_000_000, 2)
    {:ok, full_ref} = Ssim2Metric.reference(base)

    {full_us, {:ok, _full_bin, full_meta}} =
      timed(fn -> EncodeSearch.run(base, resolved, telemetry_opts: []) end)

    Enum.map(factors, fn k ->
      {ds_us, proxy} = timed(fn -> downscale(base, k) end)

      {proxy_us, {:ok, _pbin, proxy_meta}} =
        timed(fn -> EncodeSearch.run(proxy, resolved, telemetry_opts: []) end)

      {conf_us, {:ok, conf_bin}} =
        timed(fn -> Encoder.encode_to_buffer(base, resolved, proxy_meta.quality) end)

      {:ok, candidate} = Image.from_binary(conf_bin)
      {:ok, delivered} = Ssim2Metric.score(full_ref, candidate)

      pmp = Float.round(Image.width(proxy) * Image.height(proxy) / 1_000_000, 2)
      dq = proxy_meta.quality - full_meta.quality
      delta_target = delivered - @target
      hit? = delivered >= @target
      proxy_total_us = ds_us + proxy_us + conf_us
      speedup = ratio(full_us, proxy_total_us)

      IO.puts(
        pad([label, 16]) <>
          pad([mp, 6]) <>
          pad([k, 3]) <>
          pad([pmp, 6]) <>
          pad([full_meta.quality, 6]) <>
          pad([proxy_meta.quality, 7]) <>
          pad([dq, 5]) <>
          pad([fmt_score(full_meta.score), 8]) <>
          pad([fmt_score(delivered), 9]) <>
          pad([Float.round(delta_target, 2), 7]) <>
          pad([if(hit?, do: "yes", else: "NO"), 6]) <>
          pad([full_meta.bytes, 9]) <>
          pad([byte_size(conf_bin), 9]) <>
          pad(["#{speedup}x", 8])
      )

      %{
        source: label,
        mp: mp,
        k: k,
        proxy_mp: pmp,
        q_full: full_meta.quality,
        q_proxy: proxy_meta.quality,
        dq: dq,
        full_score: full_meta.score,
        delivered_score: delivered,
        delta_target: delta_target,
        hit?: hit?,
        bytes_full: full_meta.bytes,
        bytes_proxy: byte_size(conf_bin),
        full_us: full_us,
        proxy_total_us: proxy_total_us,
        speedup: speedup
      }
    end)
  end

  defp downscale(image, k) do
    {:ok, resized} = Operation.resize(image, 1.0 / k)
    resized
  end

  # Open a committed source and apply a light finalize (realize to memory, force
  # sRGB, flatten any alpha onto white) so encode_to_buffer to JPEG is valid. Real
  # production finalization (color management) is a near-no-op for these sRGB
  # sources, so this keeps Part C self-contained without the private finalize.
  defp base_image(file) do
    path = Path.join(@sources_dir, file)

    case Image.open(path, access: :random) do
      {:ok, img} ->
        {:ok, mem} = VixImage.copy_memory(img)
        {:ok, srgb} = Operation.colourspace(mem, :VIPS_INTERPRETATION_sRGB)
        flatten_alpha(srgb)

      {:error, reason} ->
        IO.puts("Part C: skipping #{file} (open failed: #{inspect(reason)})")
        nil
    end
  end

  defp flatten_alpha(image) do
    if Image.has_alpha?(image) do
      {:ok, flat} = Image.flatten(image, background_color: [255, 255, 255])
      flat
    else
      image
    end
  end

  # --- resolved descriptors --------------------------------------------------

  defp ssim2_resolved(format) do
    %Resolved{
      base_resolved(format)
      | quality: :default,
        quality_search: %RQS{
          objective: :ssim2,
          target: @target,
          min_quality: @min_q,
          max_quality: @max_q,
          allowed_error: 0,
          max_resolution: 0
        }
    }
  end

  defp size_resolved(format, budget) do
    %Resolved{
      base_resolved(format)
      | quality: :default,
        quality_search: %RQS{
          objective: :size,
          target: budget,
          min_quality: @min_q,
          max_quality: @max_q,
          allowed_error: 0,
          max_resolution: 0
        }
    }
  end

  defp max_bytes_resolved(format, budget) do
    %Resolved{base_resolved(format) | quality: :default, max_bytes: budget}
  end

  defp plain_resolved(format, quality) do
    %Resolved{base_resolved(format) | quality: {:quality, quality}}
  end

  defp base_resolved(format) do
    %Resolved{
      format: format,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :strip
    }
  end

  # --- telemetry capture -----------------------------------------------------

  defp attach_telemetry do
    :telemetry.attach(
      handler_id(),
      @prefix ++ [:encode, :search, :stop],
      &__MODULE__.handle_search_stop/4,
      self()
    )
  end

  @doc false
  def handle_search_stop(_event, _measurements, meta, target),
    do: send(target, {:bench_search_meta, meta})

  defp detach_telemetry, do: :telemetry.detach(handler_id())

  defp handler_id, do: {__MODULE__, self()}

  defp receive_search_meta do
    receive do
      {:bench_search_meta, meta} -> meta
    after
      0 -> raise "no [:encode, :search] :stop telemetry received — did the search run?"
    end
  end

  # --- synthetic source ------------------------------------------------------

  # Deterministic high-frequency zone-plate (chirp), scaled to a full-range 8-bit
  # sRGB 3-band image. The frequency sweeps to Nyquist across the frame at every
  # size, so the content is adversarial for JPEG at all resolutions — the ssim2
  # search never reaches its target band and spends its full iteration budget,
  # giving worst-case cost as a clean function of pixel count.
  defp zone_plate(w, h) do
    {:ok, z} = Operation.zone(w, h)
    {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
    {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, rgb} = Operation.bandjoin([uchar, uchar, uchar])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp zone_plate_for(mp) do
    {w, h} = square_dims(mp)
    zone_plate(w, h)
  end

  defp square_dims(mp) do
    side = round(:math.sqrt(mp * 1_000_000))
    {side, side}
  end

  # --- findings --------------------------------------------------------------

  defp print_findings(a_rows, b_rows, c_rows, format) do
    IO.puts("\n== Findings ==\n")

    if a_rows, do: findings_part_a(a_rows)
    if b_rows, do: findings_part_b(b_rows)
    if c_rows, do: findings_part_c(c_rows)

    IO.puts("\n(format: #{format}; numbers vary with CPU + libvips build — re-run locally)")
  end

  defp findings_part_a(rows) do
    avg_metric_pct = rows |> Enum.map(& &1.metric_pct) |> avg() |> round()

    over_500 = Enum.find(rows, &(&1.total_us > 500_000))
    over_1000 = Enum.find(rows, &(&1.total_us > 1_000_000))
    over_2000 = Enum.find(rows, &(&1.total_us > 2_000_000))

    IO.puts("Part A — cost curve:")
    IO.puts("  * metric dominates: ~#{avg_metric_pct}% of total wall-clock on average")
    IO.puts("  * first size over 500ms total:  #{budget_note(over_500)}")
    IO.puts("  * first size over 1000ms total: #{budget_note(over_1000)}")
    IO.puts("  * first size over 2000ms total: #{budget_note(over_2000)}")
    IO.puts("  -> recommended autoquality_max_resolution: pick the MP under your")
    IO.puts("     per-request budget from the column above (full 6x pass cost).\n")
  end

  defp budget_note(nil), do: "none in tested range"
  defp budget_note(row), do: "#{row.mp} MP (#{ms(row.total_us)} ms, #{row.iters} iters)"

  defp findings_part_b(rows) do
    scored = Enum.filter(rows, &(&1.score != nil))
    hits = Enum.count(scored, & &1.hit?)
    avg_q = scored |> Enum.map(& &1.quality) |> avg() |> round()
    avg_save = scored |> Enum.map(& &1.savings) |> avg() |> round()
    avg_iters = scored |> Enum.map(& &1.iters) |> avg() |> Float.round(1)
    avg_ssim2_ms = scored |> Enum.map(& &1.ssim2_us) |> avg() |> ms()
    avg_size_ms = rows |> Enum.map(& &1.size_us) |> avg() |> ms()
    avg_mb_ms = rows |> Enum.map(& &1.mb_us) |> avg() |> ms()

    speedup = ratio(avg(Enum.map(scored, & &1.ssim2_us)), avg(Enum.map(rows, & &1.size_us)))

    IO.puts("Part B — accuracy + behavior:")
    IO.puts("  * ssim2 hit target #{@target}: #{hits}/#{length(scored)} scored sources")

    IO.puts(
      "  * typical chosen quality ~#{avg_q}, avg savings vs q#{@baseline_quality} ~#{avg_save}%"
    )

    IO.puts("  * avg iterations: #{avg_iters} (cap #{@max_iter})")

    IO.puts(
      "  * avg cost: ssim2 #{avg_ssim2_ms} ms vs size #{avg_size_ms} ms vs max_bytes #{avg_mb_ms} ms"
    )

    IO.puts("  * ssim2 is ~#{speedup}x the cost of size (the decode+metric overhead)\n")
  end

  # Two failure modes, opposite directions:
  #   * q_proxy < q_full (Δq < 0): the proxy looked "easier" → delivered full-res
  #     score UNDERSHOOTS the target. The magnitude of −Δq is the quality margin
  #     that fixes it (the full search picks the lowest q clearing the target, so
  #     by monotonicity q_proxy ≥ q_full ⟹ delivered ≥ target).
  #   * q_proxy > q_full (Δq > 0): the proxy looked "harder" → delivered overshoots
  #     and the encode is LARGER than the optimal full-res pick — savings erode.
  # A single additive margin only addresses the first; it makes the second worse.
  defp findings_part_c(rows) do
    IO.puts("Part C — downscaled-proxy-seed method + accuracy:")

    rows
    |> Enum.group_by(& &1.k)
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.each(fn {k, group} ->
      n = length(group)
      hits = Enum.count(group, & &1.hit?)
      mean_dq = group |> Enum.map(& &1.dq) |> avg() |> Float.round(1)
      worst_dq = group |> Enum.map(& &1.dq) |> Enum.min()
      margin = max(0, -worst_dq)
      worst_under = group |> Enum.map(& &1.delta_target) |> Enum.min() |> Float.round(2)
      worst_bytes = group |> Enum.map(&byte_overshoot/1) |> Enum.max()
      mean_speedup = group |> Enum.map(& &1.speedup) |> avg() |> Float.round(1)
      mean_proxy_ms = group |> Enum.map(& &1.proxy_total_us) |> avg() |> ms()

      IO.puts(
        "  k=#{k}: hit #{hits}/#{n}@margin0  |  Δq mean #{mean_dq}/worst #{worst_dq} (+#{margin}q fixes)  |  " <>
          "worst undershoot #{worst_under}  |  worst byte overshoot +#{worst_bytes}%  |  " <>
          "~#{mean_speedup}x (#{mean_proxy_ms} ms)"
      )
    end)

    IO.puts("  -> bias direction is content-dependent: real high-detail content tends")
    IO.puts("     to over-pick q (hits target, but inflates bytes — savings erode);")
    IO.puts("     the adversarial chirp under-picks (undershoots). A modest k≈2 keeps")
    IO.puts("     both small; aggressive k needs a full-res confirm-and-adjust, not a")
    IO.puts("     fixed margin (the one full-res confirm metric is already affordable).\n")
  end

  defp byte_overshoot(%{bytes_proxy: bp, bytes_full: bf}) when bf > 0,
    do: round((bp - bf) / bf * 100)

  defp byte_overshoot(_), do: 0

  # --- CSV -------------------------------------------------------------------

  defp write_part_a_csv(rows) do
    path = "/tmp/autoquality_bench_part_a.csv"

    head =
      "mp,width,height,iters,total_us,ref_us,encode_us,decode_us,metric_us,per_iter_us,metric_pct,score,quality\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.mp},#{r.w},#{r.h},#{r.iters},#{r.total_us},#{r.ref_us},#{r.encode_us}," <>
          "#{r.decode_us},#{r.metric_us},#{r.per_iter_us},#{r.metric_pct},#{fmt_score(r.score)},#{r.quality}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("\nwrote #{path}")
  end

  defp write_part_b_csv(rows) do
    path = "/tmp/autoquality_bench_part_b.csv"

    head =
      "source,width,height,mp,quality,score,hit,bytes,baseline_bytes,savings,iters," <>
        "ssim2_us,size_us,size_iters,mb_us,mb_iters\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.w},#{r.h},#{r.mp},#{r.quality},#{fmt_score(r.score)},#{r.hit?}," <>
          "#{r.bytes},#{r.baseline_bytes},#{r.savings},#{r.iters},#{r.ssim2_us}," <>
          "#{r.size_us},#{r.size_iters},#{r.mb_us},#{r.mb_iters}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  defp write_part_c_csv(rows) do
    path = "/tmp/autoquality_bench_part_c.csv"

    head =
      "source,mp,k,proxy_mp,q_full,q_proxy,dq,full_score,delivered_score,delta_target,hit," <>
        "bytes_full,bytes_proxy,full_us,proxy_total_us,speedup\n"

    body =
      Enum.map_join(rows, fn r ->
        "#{r.source},#{r.mp},#{r.k},#{r.proxy_mp},#{r.q_full},#{r.q_proxy},#{r.dq}," <>
          "#{fmt_score(r.full_score)},#{fmt_score(r.delivered_score)},#{Float.round(r.delta_target, 2)}," <>
          "#{r.hit?},#{r.bytes_full},#{r.bytes_proxy},#{r.full_us},#{r.proxy_total_us},#{r.speedup}\n"
      end)

    File.write!(path, head <> body)
    IO.puts("wrote #{path}")
  end

  # --- helpers ---------------------------------------------------------------

  defp timed(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - t0, result}
  end

  defp parse_format("jpeg"), do: :jpeg
  defp parse_format("webp"), do: :webp
  defp parse_format("avif"), do: :avif
  defp parse_format(other), do: raise("unsupported --format #{inspect(other)} (jpeg|webp|avif)")

  defp parse_mps(nil), do: @default_mps

  defp parse_mps(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> parse_number()))
  end

  defp parse_number(s) do
    case Integer.parse(s) do
      {int, ""} -> int
      _ -> s |> Float.parse() |> elem(0)
    end
  end

  defp parse_factors(nil), do: @default_factors

  defp parse_factors(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

  defp ms(us) when is_integer(us), do: Float.round(us / 1000, 1)
  defp ms(us), do: Float.round(us / 1000, 1)

  defp pct(_part, 0), do: 0
  defp pct(part, whole), do: round(part / whole * 100)

  defp ratio(_a, 0), do: 0.0
  defp ratio(a, b), do: Float.round(a / b, 1)

  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp fmt_score(nil), do: "-"
  defp fmt_score(score), do: Float.round(score, 2)

  defp pad([value, width]), do: value |> to_string() |> String.pad_trailing(width)
end

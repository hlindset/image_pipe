defmodule ImagePipe.Output.EncodeSearchTelemetryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Telemetry
  alias Vix.Vips.Operation

  # Unique prefix so the global :telemetry handler can't catch another module's
  # default-prefixed emissions and leak them into this async test's mailbox.
  @prefix [:ip_es_test]
  @stop @prefix ++ [:encode, :search, :stop]
  @probe @prefix ++ [:encode, :search, :probe, :stop]
  @chosen @prefix ++ [:encode, :search, :probe, :chosen]

  setup do
    handler_id = "encode-search-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [@stop, @probe, @chosen],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits a search stop span and one objective probe span per distinct quality" do
    rs = %RQS.Ssimulacra2{
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    telemetry_opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    assert {:ok, _bin, %{quality: chosen_q, outcome: outcome, score: score_value}} =
             EncodeSearch.search(rs, nil,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 8,
               telemetry_opts: telemetry_opts
             )

    assert_receive {:telemetry, @stop, stop_measurements, stop_meta}
    assert is_integer(stop_measurements.duration)

    assert stop_meta.result == :ok
    assert stop_meta.objective == :ssimulacra2
    assert stop_meta.chosen_quality == chosen_q
    assert stop_meta.chosen_bytes == chosen_q * 100
    assert stop_meta.outcome == outcome
    assert stop_meta.final_score == score_value
    assert is_integer(stop_meta.iterations)
    assert stop_meta.scorer == :full
    assert stop_meta.confirm_passes == 0
    # :hit carries no limiting factor; nil metadata is stripped by the layer.
    refute Map.has_key?(stop_meta, :limiting_factor)
    # nil metadata is stripped, so the full-frame path emits no tiles_scored key.
    refute Map.has_key?(stop_meta, :tiles_scored)

    {probes, durations} = collect_probes()
    assert probes != []
    # every probe is a span: its stop measurement carries a real duration.
    assert Enum.all?(durations, &is_integer/1)

    # full-frame mode: every probe is an objective encode, carrying the phase.
    qualities = Enum.map(probes, & &1.quality)
    assert qualities == Enum.uniq(qualities)

    for probe <- probes do
      assert probe.phase == :objective
      assert is_integer(probe.quality)
      assert probe.bytes == probe.quality * 100
      assert is_integer(probe.index)
      assert is_float(probe.score)
      assert probe.scorer == :full
    end

    # the distinct-encode index is the running ordinal
    assert Enum.sort(Enum.map(probes, & &1.index)) == Enum.to_list(1..length(probes))

    # exactly one chosen marker fires, naming the delivered probe: same quality as
    # the search verdict, the objective phase that encoded it, and the shipped bytes.
    assert_receive {:telemetry, @chosen, _m, chosen}
    assert chosen.quality == chosen_q
    assert chosen.bytes == chosen_q * 100
    assert chosen.phase == :objective
    assert chosen.score == score_value
    assert chosen.scorer == :full
    assert is_integer(chosen.index)
    # full-frame mode: nil tiles_scored is stripped by the telemetry layer.
    refute Map.has_key?(chosen, :tiles_scored)
    refute_received {:telemetry, @chosen, _m2, _meta2}
  end

  test "confirm/bump probes carry the phase + the crop→full residual fields" do
    rs = %RQS.Ssimulacra2{
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    # estimate over-reports by +1: objective picks q64 (est 90), true at 64 is 89
    # (undershoot), true at 65 is 90 (clears) -> one confirm + one bump.
    estimate = fn bin -> byte_size(bin) / 100 + 26.0 end
    confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

    telemetry_opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    assert {:ok, _bin, %{quality: 65, outcome: :hit, scorer: :crop, tiles_scored: 12}} =
             EncodeSearch.search(rs, nil,
               encode_fun: enc,
               score_fun: estimate,
               confirm_fun: confirm,
               confirm_band: 90.0,
               confirm_max_quality: 80,
               max_bump_passes: 2,
               scorer: :crop,
               scorer_tiles: 12,
               telemetry_opts: telemetry_opts
             )

    {probes, _durations} = collect_probes()

    confirm_probes = Enum.filter(probes, &(&1.phase in [:confirm, :bump]))
    assert Enum.map(confirm_probes, & &1.phase) == [:confirm, :bump]

    for probe <- confirm_probes do
      assert probe.scorer == :crop
      assert probe.tiles_scored == 12
      # estimate (q+26) and authoritative full-frame (q+25) differ by exactly 1.0:
      # the crop→full residual, surfaced for shadow calibration.
      assert_in_delta probe.full_frame_score - probe.crop_estimate, -1.0, 0.001
      assert probe.score == probe.full_frame_score
      assert is_boolean(probe.passed?)
    end

    # confirm@64 undershoots (q64 -> 89 < 90); bump@65 clears (q65 -> 90).
    [confirm64, bump65] = confirm_probes
    assert confirm64.quality == 64 and confirm64.passed? == false
    assert bump65.quality == 65 and bump65.passed? == true

    # the delivered q65 was first encoded during the objective walk (probed as an
    # overshoot); the bump only re-scored those already-memoized bytes. So the
    # chosen marker names :objective — the phase that produced the shipped bytes,
    # not the phase that re-validated them.
    assert_receive {:telemetry, @chosen, _m, chosen}
    assert chosen.quality == 65
    assert chosen.phase == :objective
    assert chosen.scorer == :crop
    assert chosen.tiles_scored == 12
  end

  test "search stop names the limiting factor on a ceiling best-effort" do
    rs = %RQS.Ssimulacra2{
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    # score never reaches the band in [10, 80] -> pin to the ceiling (max_quality).
    score = fn _bin -> 50.0 end

    telemetry_opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    assert {:ok, _bin, %{outcome: :best_effort, limiting_factor: :ceiling}} =
             EncodeSearch.search(rs, nil,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 8,
               telemetry_opts: telemetry_opts
             )

    assert_receive {:telemetry, @stop, _m, stop_meta}
    assert stop_meta.outcome == :best_effort
    assert stop_meta.limiting_factor == :ceiling
  end

  test "search stop names :max_bytes when the budget cannot be met even at the floor" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end

    telemetry_opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    # max_bytes-alone: floor is q10 -> 1000 bytes, over the 500-byte budget.
    assert {:ok, _bin, %{outcome: :best_effort, limiting_factor: :max_bytes}} =
             EncodeSearch.search(:none, 500,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 8,
               telemetry_opts: telemetry_opts
             )

    assert_receive {:telemetry, @stop, _m, stop_meta}
    assert stop_meta.limiting_factor == :max_bytes

    # the floor (q10) was encoded under the cap phase, so the chosen marker names
    # :cap. :none objective carries no score → nil is stripped from the marker.
    assert_receive {:telemetry, @chosen, _m, chosen}
    assert chosen.quality == 10
    assert chosen.phase == :cap
    refute Map.has_key?(chosen, :score)
  end

  defp collect_probes(probes \\ [], durations \\ []) do
    receive do
      {:telemetry, @probe, measurements, metadata} ->
        collect_probes([metadata | probes], [measurements[:duration] | durations])
    after
      0 -> {Enum.reverse(probes), Enum.reverse(durations)}
    end
  end

  # --- classify span (#380): the per-content-class offset is selected on the crop
  # path. Uses run/3 on a real >6 MP image (so the crop scorer fires) but encodes
  # JPEG (cheap) — the classify span's offset lookup is format-agnostic, so the
  # resolved offset map can carry the avif×graphic 6.0 regardless of encode format.

  @classify @prefix ++ [:encode, :classify, :stop]

  defp attach_classify do
    handler_id = "encode-classify-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @classify,
      fn _e, _m, meta, _config -> send(test_pid, {:classify, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # >6 MP hard-edged two-tone field (dense line-art surrogate): a white canvas with
  # a fine black line grid → two luminance values (low palette entropy) + all-hard
  # edges (low mid-band) → :graphic. Built with Image.Draw, not Operation.grid.
  defp large_graphic_image do
    side = 2480
    base = Image.new!(side, side, color: :white)

    drawn =
      Enum.reduce(0..(side - 1)//16, base, fn x, acc ->
        acc
        |> Image.Draw.rect!(x, 0, 1, side, color: :black)
        |> Image.Draw.rect!(0, x, side, 1, color: :black)
      end)

    Image.to_colorspace!(drawn, :srgb)
  end

  # >6 MP continuous-tone field: a full-range luminance ramp (high palette entropy)
  # plus softly-blurred noise (high mid-band gradient) → :photo.
  defp large_photo_image do
    side = 2480
    {:ok, xyz} = Operation.xyz(side, side)
    {:ok, x} = Operation.extract_band(xyz, 0)
    {:ok, ramp} = Operation.linear(x, [255.0 / (side - 1)], [0.0])
    {:ok, noise} = Operation.gaussnoise(side, side, sigma: 35, mean: 0, seed: 1)
    {:ok, blurred} = Operation.gaussblur(noise, 1.2)
    {:ok, sum} = Operation.add(ramp, blurred)
    {:ok, uchar} = Operation.cast(sum, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp crop_resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: false,
      color_profile: :preserve_source,
      quality_search: %RQS.Ssimulacra2{
        target: 80.0,
        min_quality: 40,
        max_quality: 95,
        allowed_error: 1.0,
        max_resolution: 0,
        quality_search_offsets: %{photo: 2.4, graphic: 6.0}
      }
    }
  end

  test "classify span selects the graphic offset (6.0) for graphic content" do
    attach_classify()
    opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    assert {:ok, _bin, _meta} =
             EncodeSearch.run(large_graphic_image(), crop_resolved(),
               scorer: :crop,
               telemetry_opts: opts
             )

    assert_receive {:classify, meta}
    assert meta.content_class == :graphic
    assert meta.applied_offset == 6.0
    assert is_float(meta.palette_ent) and is_float(meta.nat_var)
  end

  test "classify span keeps the lean offset (2.4) for photo content" do
    attach_classify()
    opts = Telemetry.telemetry_opts(telemetry_prefix: @prefix)

    assert {:ok, _bin, _meta} =
             EncodeSearch.run(large_photo_image(), crop_resolved(),
               scorer: :crop,
               telemetry_opts: opts
             )

    assert_receive {:classify, meta}
    assert meta.content_class == :photo
    assert meta.applied_offset == 2.4
  end
end

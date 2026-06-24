defmodule ImagePipe.Output.EncoderCropScoringTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias Vix.Vips.Operation

  # Unique prefix so the global :telemetry handler can't leak another module's
  # default-prefixed emissions into this async test's mailbox.
  @prefix [:ip_crop_wire_test]
  @stop @prefix ++ [:encode, :search, :stop]

  defp attach_stop do
    handler_id = "crop-wire-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @stop,
      fn _event, _measurements, metadata, _config -> send(test_pid, {:stop, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Deterministic high-frequency zone-plate -> full-range 8-bit sRGB, square at `mp`.
  defp zone_plate(mp) do
    side = round(:math.sqrt(mp * 1_000_000))
    {:ok, z} = Operation.zone(side, side)
    {:ok, scaled} = Operation.linear(z, [127.5], [127.5])
    {:ok, uchar} = Operation.cast(scaled, :VIPS_FORMAT_UCHAR)
    {:ok, gray} = Operation.copy(uchar, interpretation: :VIPS_INTERPRETATION_B_W)
    {:ok, rgb} = Operation.bandjoin([gray, gray, gray])
    {:ok, srgb} = Operation.copy(rgb, interpretation: :VIPS_INTERPRETATION_sRGB)
    srgb
  end

  defp ssim2_resolved do
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
        # Content-neutral: both classes subtract the prior global 2.4, so the
        # full-vs-crop tolerance below is independent of how the zone plate
        # classifies. The per-class offset behavior is proven in the telemetry/wire
        # tests, not here.
        quality_search_offsets: %{photo: 2.4, graphic: 2.4}
      }
    }
  end

  test "stream_output crop-scores a >6 MP output with no full-frame confirm (ladder picks :crop)" do
    attach_stop()

    {:ok, [_bin], _mime} =
      Encoder.stream_output(zone_plate(7), ssim2_resolved(), telemetry_prefix: @prefix)

    assert_receive {:stop, meta}
    assert meta.scorer == :crop
    assert meta.tiles_scored == 16
    # Above the crossover the search ships the crop objective winner with no
    # full-frame confirm/bump — the O(pixels) cost the crop path exists to avoid.
    assert meta.confirm_passes == 0
  end

  test "stream_output full-frame-scores a <6 MP output (ladder picks :full)" do
    attach_stop()

    {:ok, [_bin], _mime} =
      Encoder.stream_output(zone_plate(2), ssim2_resolved(), telemetry_prefix: @prefix)

    assert_receive {:stop, meta}
    assert meta.scorer == :full
    # nil tiles_scored is stripped by the telemetry layer (full-frame has no tiles).
    refute Map.has_key?(meta, :tiles_scored)
  end

  test "crop pick tracks the full-frame search within tolerance on the same input" do
    image = zone_plate(7)
    resolved = ssim2_resolved()

    {:ok, _full_bin, full} = EncodeSearch.run(image, resolved, scorer: :full)
    {:ok, _crop_bin, crop} = EncodeSearch.run(image, resolved, scorer: :crop)

    assert crop.scorer == :crop
    # No full-frame confirm above the crossover: the crop objective winner ships as-is.
    assert crop.confirm_passes == 0
    # The conservative offset biases the estimate down, so the crop walk can land a
    # step or two higher than the full-frame pick; 4 is the robust bound. This bound
    # tracks @crop_confirm_skipped_offset — retune it together with the offset.
    assert abs(crop.quality - full.quality) <= 4
    # meta.score is the offset-corrected crop estimate the walk converged to; by
    # construction it sits at/above the band floor.
    assert crop.score >= resolved.quality_search.target - resolved.quality_search.allowed_error
  end

  test "run/3 emits the probe spans and their encode/decode/metric cost legs (crop mode)" do
    prefix = [:"ip_crop_legs_#{System.unique_integer([:positive])}"]
    test_pid = self()
    handler_id = "crop-legs-#{System.unique_integer([:positive])}"

    events =
      for stage <- [
            [:encode, :search, :probe],
            [:encode, :search, :probe, :encode],
            [:encode, :search, :probe, :ssimulacra2, :decode],
            [:encode, :search, :probe, :ssimulacra2, :metric]
          ],
          do: prefix ++ stage ++ [:stop]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, _measurements, metadata, _config ->
        stage = event |> Enum.drop(length(prefix)) |> Enum.drop(-1)
        send(test_pid, {:leg, stage, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _bin, _meta} =
      EncodeSearch.run(zone_plate(7), ssim2_resolved(),
        scorer: :crop,
        telemetry_opts: ImagePipe.Telemetry.telemetry_opts(telemetry_prefix: prefix)
      )

    legs = drain_legs()
    by_stage = Enum.group_by(legs, &elem(&1, 0), &elem(&1, 1))

    # probe spans tag their phase; above the crossover crop mode runs the objective
    # walk only — no confirm/bump phase fires.
    probe_phases = by_stage |> Map.fetch!([:encode, :search, :probe]) |> Enum.map(& &1.phase)
    assert :objective in probe_phases
    refute :confirm in probe_phases
    refute :bump in probe_phases

    # every objective/cap probe encodes -> an encode leg with the produced byte size.
    encode_legs = Map.fetch!(by_stage, [:encode, :search, :probe, :encode])
    assert encode_legs != []
    assert Enum.all?(encode_legs, &(&1.result == :ok and is_integer(&1.bytes)))

    # ssim2 scoring legs: a decode and an aggregate metric per probe.
    assert Map.fetch!(by_stage, [:encode, :search, :probe, :ssimulacra2, :decode]) != []
    metric_legs = Map.fetch!(by_stage, [:encode, :search, :probe, :ssimulacra2, :metric])
    assert metric_legs != []
    assert Enum.all?(metric_legs, &is_float(&1.score))
    # Every probe crop-scores K tiles (tiles_scored: 16); there is no whole-frame
    # confirm leg above the crossover.
    assert Enum.all?(metric_legs, &(Map.get(&1, :tiles_scored) == 16))
  end

  defp drain_legs(acc \\ []) do
    receive do
      {:leg, _stage, _meta} = msg -> drain_legs([msg | acc])
    after
      0 -> Enum.reverse(acc) |> Enum.map(fn {:leg, stage, meta} -> {stage, meta} end)
    end
  end

  test "max_bytes binds the crop-path delivered q (cap descends from the crop pick)" do
    image = zone_plate(7)
    resolved = ssim2_resolved()

    {:ok, no_cap_bin, no_cap} = EncodeSearch.run(image, resolved, scorer: :crop)
    budget = round(byte_size(no_cap_bin) * 0.5)
    capped_resolved = %Resolved{resolved | max_bytes: budget}

    {:ok, capped_bin, capped} = EncodeSearch.run(image, capped_resolved, scorer: :crop)

    # A budget below the crop pick forces cap_phase to descend: lower-or-equal
    # quality and never more bytes than the uncapped pick.
    assert capped.quality <= no_cap.quality
    assert byte_size(capped_bin) <= byte_size(no_cap_bin)
  end
end

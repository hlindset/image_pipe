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
      quality_search: %RQS{
        objective: :ssim2,
        target: 80.0,
        min_quality: 40,
        max_quality: 95,
        allowed_error: 1.0,
        max_resolution: 0
      }
    }
  end

  test "stream_output crop-scores a >6 MP output (ladder picks :crop)" do
    attach_stop()

    {:ok, [_bin], _mime} =
      Encoder.stream_output(zone_plate(7), ssim2_resolved(), telemetry_prefix: @prefix)

    assert_receive {:stop, meta}
    assert meta.scorer == :crop
    assert meta.tiles_scored == 16
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
    assert crop.confirm_passes >= 1
    # Part E residual is ±2-4 q; 3 is the robust bound. Re-confirm after the bench
    # sets the calibrated @crop_macro_offset; tighten to <= 2 only if it supports it.
    assert abs(crop.quality - full.quality) <= 3
    assert crop.score >= resolved.quality_search.target - resolved.quality_search.allowed_error
  end

  test "max_bytes binds the crop-path delivered q (cap runs after confirm/bump)" do
    image = zone_plate(7)
    resolved = ssim2_resolved()

    {:ok, no_cap_bin, no_cap} = EncodeSearch.run(image, resolved, scorer: :crop)
    budget = round(byte_size(no_cap_bin) * 0.5)
    capped_resolved = %Resolved{resolved | max_bytes: budget}

    {:ok, capped_bin, capped} = EncodeSearch.run(image, capped_resolved, scorer: :crop)

    # A budget below the crop pick forces cap_phase (which runs AFTER confirm/bump) to
    # descend: lower-or-equal quality and never more bytes than the uncapped pick.
    assert capped.quality <= no_cap.quality
    assert byte_size(capped_bin) <= byte_size(no_cap_bin)
  end
end

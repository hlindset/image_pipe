defmodule ImagePipe.Output.EncodeSearchTelemetryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Telemetry

  # Unique prefix so the global :telemetry handler can't catch another module's
  # default-prefixed emissions and leak them into this async test's mailbox.
  @prefix [:ip_es_test]
  @stop @prefix ++ [:encode, :search, :stop]
  @probe @prefix ++ [:encode, :search, :probe]

  setup do
    handler_id = "encode-search-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [@stop, @probe],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "emits a search stop span and one probe per distinct quality" do
    rs = %RQS{
      objective: :ssim2,
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
    assert stop_meta.objective == :ssim2
    assert stop_meta.chosen_quality == chosen_q
    assert stop_meta.chosen_bytes == chosen_q * 100
    assert stop_meta.outcome == outcome
    assert stop_meta.final_score == score_value
    assert is_integer(stop_meta.iterations)
    assert stop_meta.scorer == :full
    assert stop_meta.confirm_passes == 0
    # nil metadata is stripped by the telemetry layer, so the full-frame path
    # emits no tiles_scored key (it's a crop-only measurement).
    refute Map.has_key?(stop_meta, :tiles_scored)

    probes = collect_probes()
    assert probes != []

    # one probe per distinct probed quality, carrying product-neutral numbers
    qualities = Enum.map(probes, & &1.quality)
    assert qualities == Enum.uniq(qualities)

    for probe <- probes do
      assert is_integer(probe.quality)
      assert probe.bytes == probe.quality * 100
      assert is_integer(probe.index)
      assert is_float(probe.score)
    end

    # the distinct-encode index is the running ordinal
    assert Enum.sort(Enum.map(probes, & &1.index)) == Enum.to_list(1..length(probes))
  end

  defp collect_probes(acc \\ []) do
    receive do
      {:telemetry, @probe, _measurements, metadata} -> collect_probes([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

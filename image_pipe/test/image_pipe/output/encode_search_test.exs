defmodule ImagePipe.Output.EncodeSearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  test "ssim2 accepts a start quality that already lands in the band" do
    rs = %RQS.Ssimulacra2{
      target: 75.0,
      min_quality: 25,
      max_quality: 95,
      start_quality: 55,
      allowed_error: 0.5
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 55, outcome: :hit, iterations: 1}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score)
  end

  test "ssim2 steps from a poor start toward the target instead of bisecting" do
    # score = 0.5q + 40 reaches 75 at q70. From a start at q30 (score 55) the
    # first step assumes one point per quality (q50, score 65), the second
    # measures the real slope and lands on q70.
    rs = %RQS.Ssimulacra2{
      target: 75.0,
      min_quality: 25,
      max_quality: 95,
      start_quality: 30,
      allowed_error: 0.5
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 * 0.5 + 40.0 end

    assert {:ok, _bin, %{quality: 70, outcome: :hit, iterations: 3}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score)
  end

  test "ssim2 lands on the quality matching the target (zero-width band)" do
    rs = %RQS.Ssimulacra2{
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    # score = q + 20, so the target (90) is reached exactly at q70; the zero-width
    # band [90, 90] converges there.
    assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

    assert s >= 90.0
  end

  test "ssim2 reports :hit at the default iteration cap on a realistic bracket" do
    rs = %RQS.Ssimulacra2{
      target: 90.0,
      min_quality: 70,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 70, outcome: :hit}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 6)
  end

  test "ssim2 walk-to-target converges toward the target, not the band floor" do
    # target 80, allowed_error 5 → symmetric band [75, 85]. score = q + 20, so the
    # target (80) is reached at q60 and the band floor (75) at q55. The old
    # lowest-satisfying search shipped q55 (the floor); walk-to-target ships an
    # in-band quality at the target (q60, score 80) instead.
    rs = %RQS.Ssimulacra2{
      target: 80.0,
      min_quality: 10,
      max_quality: 90,
      allowed_error: 5.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 60, outcome: :hit, score: 80.0}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "ssim2 empty band ships the nearest overshoot (the just-above quality)" do
    # Integer-quality granularity straddles a narrow band: score = 2q + 19 jumps by
    # 2 per quality, and band [79.5, 80.5] (target 80, allowed_error 0.5) is empty —
    # q30 → 79 (undershoot), q31 → 81 (overshoot), nothing lands inside. Walk-to-target
    # ships the lowest overshoot (q31, score 81 ≥ target), a :hit, never the undershoot.
    rs = %RQS.Ssimulacra2{
      target: 80.0,
      min_quality: 10,
      max_quality: 40,
      allowed_error: 0.5
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 * 2 + 19.0 end

    assert {:ok, _bin, %{quality: 31, outcome: :hit, score: 81.0}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "ssim2 crosses a score jump instead of creeping along the failing side" do
    # JPEG switches from 4:2:0 to 4:4:4 chroma at q90, so the score jumps about ten
    # points there (measured on a 5.5 MP chart screenshot). Once q91 passes far
    # above the band, interpolating between it and q80 creeps up one quality at a
    # time (q82, q83, q84) until the six probes run out and q91 ships, although
    # q85 and q86 score in the band. The bracket is far steeper than the failing
    # side, so the search probes its midpoint instead.
    rs = %RQS.Ssimulacra2{
      target: 75.0,
      min_quality: 25,
      max_quality: 95,
      start_quality: 76,
      allowed_error: 0.5
    }

    scores = %{
      76 => 70.52,
      80 => 71.75,
      82 => 73.34,
      83 => 73.92,
      84 => 74.48,
      85 => 75.21,
      86 => 75.74,
      87 => 76.28,
      91 => 87.58
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> Map.fetch!(scores, div(byte_size(bin), 100)) end

    assert {:ok, _bin, %{quality: 86, outcome: :hit, score: 75.74, iterations: 4}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score)
  end

  test "ssim2 ships the floor when even min_quality overshoots the band (easy image)" do
    # Easy content: even min_quality (q10) scores above target + allowed_error, so the
    # band is unreachable from below. score = q + 60, band [48, 52] (target 50,
    # allowed_error 2): every quality overshoots. Walk-to-target descends to the floor
    # and ships min_quality (smallest file, quality still ≥ target), a :hit.
    rs = %RQS.Ssimulacra2{
      target: 50.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 2.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 60.0 end

    assert {:ok, _bin, %{quality: 10, outcome: :hit, score: 70.0}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "ssim2 best-effort pins the ceiling when the target is unreachable (all undershoot)" do
    rs = %RQS.Ssimulacra2{
      target: 99.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 / 2.0 end

    assert {:ok, _bin, %{quality: 80, outcome: :best_effort, limiting_factor: :ceiling}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "max_bytes lowers the ssim2 pick when it exceeds the budget" do
    rs = %RQS.Ssimulacra2{
      target: 80.0,
      min_quality: 10,
      max_quality: 90,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    score = fn bin -> byte_size(bin) / 1000 end

    # meta.score must reflect the DELIVERED q=60 (score == q == 60.0), not the
    # objective pick's q=80 score.
    assert {:ok, _bin, %{quality: 60, score: 60.0}} =
             EncodeSearch.search(rs, 60_000,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 16
             )
  end

  test "the max_bytes phase scores only the quality it ships" do
    rs = %RQS.Ssimulacra2{target: 80.0, min_quality: 10, max_quality: 90, allowed_error: 0.0}
    test = self()
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    score = fn bin ->
      send(test, {:scored, byte_size(bin) / 1000})
      byte_size(bin) / 1000
    end

    assert {:ok, _bin, %{quality: 60, score: 60.0}} =
             EncodeSearch.search(rs, 60_000,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 16
             )

    # The objective phase scores its probes, 50 to 80. The max_bytes phase
    # probes below 80 by size alone, then scores only the 60 it ships.
    assert Enum.sort(collect_scores([])) == [50.0, 60.0, 70.0, 80.0]
  end

  test "the max_bytes phase searches only between the sizes the objective phase measured" do
    rs = %RQS.Ssimulacra2{target: 80.0, min_quality: 10, max_quality: 90, allowed_error: 0.0}
    test = self()

    enc = fn q ->
      send(test, {:encoded, q})
      {:ok, :binary.copy(<<0>>, q * 1000)}
    end

    assert {:ok, _bin, %{quality: 65}} =
             EncodeSearch.search(rs, 65_000,
               encode_fun: enc,
               score_fun: &(byte_size(&1) / 1000),
               max_iterations: 16
             )

    # The objective phase measured 60 (fits) and 70 (doesn't), so the
    # max_bytes phase looks only between them.
    encoded = collect_encoded([])
    assert Enum.all?(encoded, &(&1 >= 50)), inspect(encoded)
    assert encoded |> Enum.filter(&(&1 > 60 and &1 < 70)) |> Enum.sort() == [65, 66, 67]
  end

  defp collect_encoded(acc) do
    receive do
      {:encoded, q} -> collect_encoded([q | acc])
    after
      0 -> acc
    end
  end

  defp collect_scores(acc) do
    receive do
      {:scored, q} -> collect_scores([q | acc])
    after
      0 -> acc
    end
  end

  test "an objective search doesn't leave max_bytes a lower quality than max_bytes alone" do
    rs = %RQS.Ssimulacra2{
      target: 80.0,
      min_quality: 25,
      max_quality: 95,
      start_quality: 30,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    score = fn bin -> byte_size(bin) / 1000 end

    {:ok, _bin, alone} = EncodeSearch.search(:none, 60_000, encode_fun: enc, base_quality: 90)

    {:ok, _bin, combined} =
      EncodeSearch.search(rs, 60_000, encode_fun: enc, score_fun: score)

    assert combined.outcome == :hit
    assert combined.quality >= alone.quality
  end

  test "max_bytes alone searches [10, base] for the highest fit" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 40, outcome: :hit}} =
             EncodeSearch.search(:none, 40_000,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 8
             )
  end

  test "max_bytes alone reports :hit when the base quality already fits" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    # base 90 -> 90_000 bytes, already <= 200_000: no descent, but a satisfied budget.
    assert {:ok, _bin, %{quality: 90, outcome: :hit}} =
             EncodeSearch.search(:none, 200_000,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 8
             )
  end

  test "max_bytes alone reports :best_effort when even the floor exceeds the budget" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    # floor 10 -> 10_000 bytes > 5_000: best-effort floor.
    assert {:ok, _bin, %{quality: 10, outcome: :best_effort}} =
             EncodeSearch.search(:none, 5_000,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 8
             )
  end

  test "max_bytes with no iterations left reuses the highest probed quality that fits" do
    # The objective probes q50, q70, q80 and spends the cap. q80 is over the
    # budget, so the cap phase can't probe. q50 fits and ships, not the floor.
    rs = %RQS.Ssimulacra2{
      target: 80.0,
      min_quality: 10,
      max_quality: 90,
      start_quality: 50,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end
    score = fn bin -> byte_size(bin) / 1000 end

    assert {:ok, _bin, %{quality: 50, outcome: :hit, limiting_factor: nil}} =
             EncodeSearch.search(rs, 60_000,
               encode_fun: enc,
               score_fun: score,
               max_iterations: 3,
               cap_iterations: 0
             )
  end

  test "max_bytes with no iterations left reports a floor that fits as a :hit" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 10, outcome: :hit, limiting_factor: nil}} =
             EncodeSearch.search(:none, 40_000,
               encode_fun: enc,
               base_quality: 90,
               max_iterations: 1,
               cap_iterations: 0
             )
  end

  test "max_bytes alone never raises an explicit quality below the normal floor" do
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 5, outcome: :best_effort}} =
             EncodeSearch.search(:none, 1_000,
               encode_fun: enc,
               base_quality: 5,
               max_iterations: 8
             )
  end

  # Task 13b

  describe "crop scorer" do
    test "the objective converges toward the target within the band" do
      # target 90, allowed_error 5 → band [85, 91]; estimate = q + 25. The search
      # steps from the midpoint (q45, estimate 70) to q65 (estimate 90, the
      # target), not to the band floor q60 (estimate 85).
      rs = %RQS.Ssimulacra2{
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 5.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      estimate = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 scorer: :crop,
                 scorer_tiles: 16
               )

      assert meta.quality == 65
      assert meta.outcome == :hit
    end

    test "scorer/tiles flow through meta from the opts" do
      rs = %RQS.Ssimulacra2{
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      score = fn bin -> byte_size(bin) / 100 + 20.0 end

      # full mode: default scorer
      assert {:ok, _b, %{quality: 70, scorer: :full, tiles_scored: nil}} =
               EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

      # crop mode: scorer/tiles flow through meta from the opts.
      assert {:ok, _b, %{quality: 70, scorer: :crop, tiles_scored: 16}} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: score,
                 scorer: :crop,
                 scorer_tiles: 16,
                 max_iterations: 8
               )
    end
  end

  describe "score_setup" do
    test "builds the score function once, right before the first score" do
      rs = %RQS.Ssimulacra2{
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      test_pid = self()

      enc = fn q ->
        send(test_pid, {:encoded, q})
        {:ok, :binary.copy(<<0>>, q * 100)}
      end

      setup = fn ->
        send(test_pid, :setup)
        fn bin -> byte_size(bin) / 100 + 20.0 end
      end

      assert {:ok, _b, %{quality: 70}} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_setup: setup,
                 max_iterations: 8
               )

      {:messages, messages} = Process.info(self(), :messages)
      assert [{:encoded, _first}, :setup | rest] = messages
      refute :setup in rest
    end
  end

  describe "max_search_pixels" do
    defp target_search,
      do: %RQS.Ssimulacra2{target: 90.0, min_quality: 10, max_quality: 80, allowed_error: 0.0}

    # score = q + 20 reaches the target at q70, three probes from the q45 start.
    defp enc, do: fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    defp score, do: fn bin -> byte_size(bin) / 100 + 20.0 end

    test "stops probing at the limit and ships what the search has" do
      assert {:ok, _bin,
              %{
                quality: 80,
                iterations: 3,
                outcome: :best_effort,
                limiting_factor: :search_pixels,
                pixel_limited: true
              }} =
               EncodeSearch.search(target_search(), nil,
                 encode_fun: enc(),
                 score_fun: score(),
                 frame_pixels: 100,
                 max_search_pixels: 250
               )
    end

    test "a limit below one frame still delivers one encode" do
      assert {:ok, _bin,
              %{
                quality: 80,
                iterations: 1,
                outcome: :best_effort,
                limiting_factor: :search_pixels
              }} =
               EncodeSearch.search(target_search(), nil,
                 encode_fun: enc(),
                 score_fun: score(),
                 frame_pixels: 100,
                 max_search_pixels: 50
               )
    end

    test "a max-bytes search at the limit still tries the floor" do
      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

      assert {:ok, _bin, %{quality: 10, iterations: 2, outcome: :hit, pixel_limited: true}} =
               EncodeSearch.search(:none, 40_000,
                 encode_fun: enc,
                 base_quality: 90,
                 frame_pixels: 100,
                 max_search_pixels: 150
               )
    end

    test "a limit the search stays within changes nothing" do
      for limit <- [:infinity, 1_000] do
        assert {:ok, _bin, %{quality: 70, outcome: :hit, iterations: 3, pixel_limited: false}} =
                 EncodeSearch.search(target_search(), nil,
                   encode_fun: enc(),
                   score_fun: score(),
                   frame_pixels: 100,
                   max_search_pixels: limit
                 )
      end
    end
  end
end

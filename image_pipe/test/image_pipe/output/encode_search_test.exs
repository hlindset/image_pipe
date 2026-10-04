defmodule ImagePipe.Output.EncodeSearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

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
  test "skip?/2 true when megapixels exceed a positive max_resolution" do
    assert EncodeSearch.skip?(%{max_resolution: 2}, 5)
    refute EncodeSearch.skip?(%{max_resolution: 0}, 100)
    refute EncodeSearch.skip?(%{max_resolution: 10}, 5)
  end

  describe "crop scorer" do
    test "the objective converges toward the target within the band" do
      # target 90, allowed_error 5 → band [85, 95]; estimate = q + 25. The walk lands
      # on q63 (estimate 88, in band), not the band floor q60 (estimate 85).
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

      assert meta.quality == 63
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
end

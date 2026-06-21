defmodule ImagePipe.Output.EncodeSearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  test "size picks the highest quality under the byte target" do
    rs = %RQS{objective: :size, target: 50_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 50, outcome: :hit}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
  end

  test "size best-effort returns min_quality when even the floor exceeds the budget" do
    rs = %RQS{objective: :size, target: 5_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 10, outcome: :best_effort}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
  end

  test "ssim2 picks the lowest quality clearing the tolerance band" do
    rs = %RQS{
      objective: :ssim2,
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

    assert s >= 90.0
  end

  test "ssim2 reports :hit at the default iteration cap on a realistic bracket" do
    rs = %RQS{
      objective: :ssim2,
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

  test "ssim2 allowed_error loosens the band downward" do
    rs = %RQS{
      objective: :ssim2,
      target: 90.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 5.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 + 20.0 end

    assert {:ok, _bin, %{quality: 65}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "ssim2 best-effort returns max_quality when target unreachable" do
    rs = %RQS{
      objective: :ssim2,
      target: 99.0,
      min_quality: 10,
      max_quality: 80,
      allowed_error: 0.0
    }

    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
    score = fn bin -> byte_size(bin) / 100 / 2.0 end

    assert {:ok, _bin, %{quality: 80, outcome: :best_effort}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)
  end

  test "max_bytes lowers the ssim2 pick when it exceeds the budget" do
    rs = %RQS{
      objective: :ssim2,
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

  # Task 13b
  test "skip?/2 true when megapixels exceed a positive max_resolution" do
    assert EncodeSearch.skip?(%{max_resolution: 2}, 5)
    refute EncodeSearch.skip?(%{max_resolution: 0}, 100)
    refute EncodeSearch.skip?(%{max_resolution: 10}, 5)
  end

  describe "confirm phase (objective-neutral re-validation)" do
    # The objective score_fun is an ESTIMATE (e.g. crop p10 - offset); the
    # confirm_fun is the AUTHORITATIVE measure. confirm_band is target-allowed_error.
    test "no confirm_fun is a pure passthrough (today's behavior)" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      score = fn bin -> byte_size(bin) / 100 + 20.0 end

      assert {:ok, _bin, %{quality: 70, outcome: :hit, score: s}} =
               EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

      assert s >= 90.0
    end

    test "confirm clears at the objective winner -> :hit, 1 confirm pass, authoritative score" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate accurate at the boundary: objective picks q65 (65+25=90) and the
      # confirm clears there immediately (no bump). score = q + 25.
      estimate = fn bin -> byte_size(bin) / 100 + 25.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 65
      assert meta.outcome == :hit
      assert meta.score >= 90.0
      assert meta.confirm_passes == 1
    end

    test "undershoot bumps up to clear (2 confirm passes)" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate over-reports by +6: objective picks q64 (est 90), true at 64 is 89 (undershoot),
      # true at 65 is 90 (clears) -> bump +1.
      estimate = fn bin -> byte_size(bin) / 100 + 26.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 65
      assert meta.outcome == :hit
      assert meta.score >= 90.0
      assert meta.confirm_passes == 2
    end

    test "bump-cap exhaustion ships best-effort at the highest q tried" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # estimate clears at q60 (60+30=90) but the TRUE score never reaches 90 in [60,62]:
      # true = bytes/100 + 25 -> q60..62 give 85..87, all undershoot; cap 2 -> best-effort at 62.
      estimate = fn bin -> byte_size(bin) / 100 + 30.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2
               )

      assert meta.quality == 62
      assert meta.outcome == :best_effort
      assert meta.confirm_passes == 3
    end

    test "max_bytes binds the final q AFTER the confirm/bump (cap runs last)" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      # objective (estimate q+26) picks q64; confirm (q+25) undershoots at 64, bumps to 65.
      estimate = fn bin -> byte_size(bin) / 100 + 26.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      # budget 6300 bytes => q <= 63. The bump lands on 65 (6500b > budget), so the
      # cap_phase (which runs AFTER confirm/bump) must descend to 63.
      # max_iterations 16 so the objective + confirm/bump + cap-descend all have
      # probe budget (same convention as the existing max_bytes ssim2 test).
      assert {:ok, bin, meta} =
               EncodeSearch.search(rs, 6300,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2,
                 max_iterations: 16
               )

      assert meta.quality == 63
      assert byte_size(bin) <= 6300
    end

    test "scorer/tiles flow through meta from the opts" do
      rs = %RQS{
        objective: :ssim2,
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
      assert {:ok, _b, %{quality: q, scorer: :crop, tiles_scored: 16}} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: score,
                 confirm_fun: score,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 scorer: :crop,
                 scorer_tiles: 16,
                 max_iterations: 8
               )

      assert is_integer(q)
    end

    test "confirm_passes is 0 when no confirm_fun is provided (full-frame path)" do
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      score = fn bin -> byte_size(bin) / 100 + 20.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil, encode_fun: enc, score_fun: score, max_iterations: 8)

      assert meta.confirm_passes == 0
    end

    test "allowed_error > 0 widens the confirm_band so a smaller offset clears" do
      # target 90, allowed_error 5 -> band 85.
      # estimate is exact (no over-report), winner at band 85 clears confirm immediately.
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 5.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      estimate = fn bin -> byte_size(bin) / 100 + 20.0 end
      # confirm_band is 90.0 - 5.0 = 85.0; confirm fn returns same as estimate
      confirm = fn bin -> byte_size(bin) / 100 + 20.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 85.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2,
                 max_iterations: 8
               )

      assert meta.outcome == :hit
      assert meta.confirm_passes == 1
      assert meta.score >= 85.0
    end

    test "bump is capped at confirm_max_quality (no bump beyond the bracket ceiling)" do
      # objective picks q79 (79+11=90 >= 90); confirm (q+10) gives q79->89 (undershoot).
      # Only 1 bump slot: q80 = confirm_max_quality, true score 80+10=90 -> clears.
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      estimate = fn bin -> byte_size(bin) / 100 + 11.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 10.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2,
                 max_iterations: 16
               )

      assert meta.quality == 80
      assert meta.outcome == :hit
      assert meta.score >= 90.0
      # 2 passes: 1 confirm at q79 (miss) + 1 bump to q80 (hit)
      assert meta.confirm_passes == 2
    end

    test "confirm memoization prevents double-counting passes for the same quality" do
      # If the same q ends up in both the objective winner path and the cap phase
      # (i.e. cap doesn't relocate), confirm_score for that q must be idempotent.
      # We exercise this by running confirm with a confirm_fun that mutates a counter
      # and asserting the confirm count equals 1 (not 2).
      rs = %RQS{
        objective: :ssim2,
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 0.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      estimate = fn bin -> byte_size(bin) / 100 + 25.0 end
      confirm_calls = :counters.new(1, [])
      confirm = fn bin ->
        :counters.add(confirm_calls, 1, 1)
        byte_size(bin) / 100 + 25.0
      end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 90.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2,
                 max_iterations: 8
               )

      # Confirm clears on first pass; memoization means the same q is not re-scored.
      assert meta.confirm_passes == 1
      assert :counters.get(confirm_calls, 1) == 1
    end
  end
end

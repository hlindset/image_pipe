defmodule ImagePipe.Output.EncodeSearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  test "size picks the highest quality under the byte target" do
    rs = %RQS.Size{target: 50_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 50, outcome: :hit}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
  end

  test "size best-effort returns min_quality when even the floor exceeds the budget" do
    rs = %RQS.Size{target: 5_000, min_quality: 10, max_quality: 80}
    enc = fn q -> {:ok, :binary.copy(<<0>>, q * 1000)} end

    assert {:ok, _bin, %{quality: 10, outcome: :best_effort}} =
             EncodeSearch.search(rs, nil, encode_fun: enc, max_iterations: 8)
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
      rs = %RQS.Ssimulacra2{
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
      rs = %RQS.Ssimulacra2{
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
      rs = %RQS.Ssimulacra2{
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
      rs = %RQS.Ssimulacra2{
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
      rs = %RQS.Ssimulacra2{
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

    test "crop mode: the objective converges toward the target, the confirm floor still guards" do
      # target 90, allowed_error 5 → estimate band [85, 95]; the confirm floor is
      # target - allowed_error = 85 (kept one-sided, bump walks up). estimate = q + 25
      # (accurate). Walk-to-target lands the objective at q63 (estimate 88, in band) —
      # NOT the old floor pick q60 (estimate 85). The confirm re-validates against the
      # floor (85) and clears immediately, so the objective and confirm stay coherent.
      rs = %RQS.Ssimulacra2{
        target: 90.0,
        min_quality: 10,
        max_quality: 80,
        allowed_error: 5.0
      }

      enc = fn q -> {:ok, :binary.copy(<<0>>, q * 100)} end
      estimate = fn bin -> byte_size(bin) / 100 + 25.0 end
      confirm = fn bin -> byte_size(bin) / 100 + 25.0 end

      assert {:ok, _bin, meta} =
               EncodeSearch.search(rs, nil,
                 encode_fun: enc,
                 score_fun: estimate,
                 confirm_fun: confirm,
                 confirm_band: 85.0,
                 confirm_max_quality: 80,
                 max_bump_passes: 2,
                 scorer: :crop,
                 scorer_tiles: 16
               )

      assert meta.quality == 63
      assert meta.outcome == :hit
      assert meta.confirm_passes == 1
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
  end

  describe "lower_better (butteraugli distance) band search" do
    # bytes == q, so a score_fun keyed on byte_size recovers q. distance score
    # decreases as quality rises: score(q) = 3.0 - q/50.
    defp const_encode, do: fn q -> {:ok, :binary.copy(<<0>>, q)} end
    defp distance_score, do: fn bytes -> 3.0 - byte_size(bytes) / 50 end

    test "lower_better band search converges to in-band quality" do
      # target 1.0 ± 0.1 → band [0.9, 1.1]; within 70..95 only q95 (score 1.1) is
      # in-band, so the inverted walk drives upward and lands there.
      search = %RQS.Butteraugli{target: 1.0, min_quality: 70, max_quality: 95, allowed_error: 0.1}

      assert {:ok, _bin, meta} =
               EncodeSearch.search(search, nil,
                 encode_fun: const_encode(),
                 score_fun: distance_score(),
                 max_iterations: 12
               )

      assert meta.outcome in [:hit, :best_effort]
      assert meta.quality in 70..95
      assert meta.score <= 1.1
    end

    test "lower_better: distance above the band never clears → pins to the ceiling" do
      # target 0.5 ± 0.05 → band [0.45, 0.55]; score(95) = 1.1 > band_hi, so even
      # max quality is too lossy. No acceptable overshoot ever recorded → ceiling pin.
      search =
        %RQS.Butteraugli{target: 0.5, min_quality: 70, max_quality: 95, allowed_error: 0.05}

      assert {:ok, _bin, meta} =
               EncodeSearch.search(search, nil,
                 encode_fun: const_encode(),
                 score_fun: distance_score(),
                 max_iterations: 12
               )

      assert meta.quality == 95
      assert meta.outcome == :best_effort
      assert meta.limiting_factor in [:ceiling, :floor]
    end

    test "lower_better straddle: empty band ships the lower-distance (higher-q) side as :hit" do
      # target 1.51 ± 0.001 → band [1.509, 1.511]. score = 3 - q/50, so the band
      # crosses between q74 (1.52, above band) and q75 (1.50, below band); no integer
      # q lands in-band. The acceptable (lower-distance / higher-quality) side wins.
      search =
        %RQS.Butteraugli{target: 1.51, min_quality: 70, max_quality: 95, allowed_error: 0.001}

      assert {:ok, _bin, meta} =
               EncodeSearch.search(search, nil,
                 encode_fun: const_encode(),
                 score_fun: distance_score(),
                 max_iterations: 12
               )

      assert meta.quality == 75
      assert meta.outcome == :hit
      assert meta.score < 1.509
    end
  end

  describe "native jxl butteraugli (run/3)" do
    @tag :jxl
    test "no max_bytes → single encode, outcome :native, no NIF" do
      {:ok, img} = Image.new(128, 128, color: [10, 20, 30])

      resolved =
        native_resolved(nil, target: 1.0, min_quality: 1, max_quality: 100, allowed_error: 0.1)

      assert {:ok, bin, meta} = EncodeSearch.run(img, resolved, [])
      assert {:ok, _} = Image.from_binary(bin)
      assert meta.outcome == :native
      assert meta.iterations == 0
      assert meta.score == nil
    end

    @tag :jxl
    test "explicit max_quality is never exceeded" do
      # target 1.0 (= Q90) with max_quality 80 (= dist 1.9) → the Q-bracket clamp
      # raises the effective distance to dist(Q80)=1.9, never a higher quality
      # (lower distance) than the bracket ceiling. With max_quality 100 the bracket
      # does not bite and the target distance 1.0 (= Q90) is used directly.
      # We assert the clamp by byte-identity to the explicit Q encode (a byte-size
      # comparison is not a reliable proxy — JXL byte size is non-monotone on a flat
      # synthetic image), which proves max_quality=80 capped the quality.
      {:ok, img} = Image.new(256, 256, color: [200, 60, 60])

      clamped =
        native_resolved(nil, target: 1.0, min_quality: 1, max_quality: 80, allowed_error: 0.1)

      uncapped = put_in(clamped.quality_search.max_quality, 100)

      {:ok, capped_bin, _} = EncodeSearch.run(img, clamped, [])
      {:ok, free_bin, _} = EncodeSearch.run(img, uncapped, [])

      {:ok, q80} = Vix.Vips.Image.write_to_buffer(img, ".jxl[Q=80]")
      {:ok, q90} = Vix.Vips.Image.write_to_buffer(img, ".jxl[Q=90]")

      # Capped honors max_quality 80: byte-identical to the explicit Q80 encode,
      # and distinct from the uncapped Q90 encode.
      assert capped_bin == q80
      assert free_bin == q90
      refute capped_bin == free_bin
    end

    @tag :jxl
    test "max_bytes degrades distance and self-caps" do
      # A high-frequency photo so distance genuinely trades bytes (a flat synthetic
      # image hits libjxl's irreducible floor and can never honor a sub-floor budget).
      {:ok, img} =
        Image.open("test/support/image_pipe/test/imgproxy_differential/sources/high_freq.jpg")

      {:ok, big, _} =
        EncodeSearch.run(
          img,
          native_resolved(nil, target: 0.3, min_quality: 1, max_quality: 100, allowed_error: 0.05),
          []
        )

      budget = div(byte_size(big), 2)

      {:ok, capped, meta} =
        EncodeSearch.run(
          img,
          native_resolved(budget,
            target: 0.3,
            min_quality: 1,
            max_quality: 100,
            allowed_error: 0.05
          ),
          []
        )

      assert byte_size(capped) <= budget
      assert meta.outcome in [:native, :best_effort]
    end
  end

  defp native_resolved(max_bytes, opts) do
    %Resolved{
      format: :jpeg_xl,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip,
      max_bytes: max_bytes,
      quality_search: struct!(RQS.NativeJxlButteraugli, opts)
    }
  end
end

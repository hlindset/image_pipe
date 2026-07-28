defmodule ImagePipe.Transform.DecodePlannerRequestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.DecodePlanner.Request

  @formats [:jpeg, :webp, :png]

  # The oracle: the same load options the planner chooses for the equivalent
  # semantic operation chain, reached through `request_from_chain/3`.
  defp chain_options(chain, format, dims, exif_quarter_turn? \\ false, auto_rotate? \\ false) do
    chain
    |> DecodePlanner.request_from_chain(dims, exif_quarter_turn? and auto_rotate?)
    |> DecodePlanner.open_options_for(format, dims, exif_quarter_turn?, auto_rotate?)
  end

  # --- Parity: crop_extent + resize_target vs. an equivalent chain ---

  test "resize_target + crop_extent matches an equivalent chain across formats" do
    # src 3200x2400; crop 1600x1200 feeds a fit:400x300 resize (no dpr/zoom) ->
    # crop/target ratio = min(1600/400, 1200/300) = 4.
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 1600}, {:px, 1200})
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 300})
    chain = [crop, resize]

    request = %Request{resize_target: {400, 300}, crop_extent: {1600, 1200}}

    for format <- @formats do
      expected = chain_options(chain, format, {3200, 2400})
      actual = DecodePlanner.open_options_for(request, format, {3200, 2400})

      assert actual == expected,
             "mismatch for #{format}: #{inspect(actual)} != #{inspect(expected)}"
    end
  end

  test "resize_target axis swap matches an equivalent chain across formats and quarter-turn values" do
    # src 3200x800 (landscape); an asymmetric target (200x50) makes the swap change
    # which axis governs the min(), so the two quarter-turn settings genuinely
    # diverge, and both entry points must diverge identically.
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, {:px, 50})
    chain = [resize]

    request = %Request{resize_target: {200, 50}}

    for format <- @formats, {exif_qt?, auto_rotate?} <- [{false, false}, {true, true}] do
      expected = chain_options(chain, format, {3200, 800}, exif_qt?, auto_rotate?)

      actual =
        DecodePlanner.open_options_for(request, format, {3200, 800}, exif_qt?, auto_rotate?)

      assert actual == expected,
             "mismatch for #{format}/#{exif_qt?}/#{auto_rotate?}: #{inspect(actual)} != #{inspect(expected)}"
    end
  end

  # --- user_quarter_turn? XORs with the EXIF turn ---
  #
  # Every expectation below is derived from the chain path, which owns the same
  # rule (`rem(exif_angle + user_angle, 180) == 90`). The chain is the oracle;
  # the hand-built `%Request{}` form must agree with it.

  test "user_quarter_turn? swaps the shrink axes when there is no EXIF turn" do
    # src 3200x800; a rot:90 before a fit:200x50 resize means the target's axes
    # are the stored axes swapped -> shrink computed against {800, 3200}.
    assert {:ok, rotate} = Operation.rotate(90)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, {:px, 50})
    chain = [rotate, resize]

    request = %Request{resize_target: {200, 50}, user_quarter_turn?: true}

    for format <- @formats do
      expected = chain_options(chain, format, {3200, 800}, false, false)
      actual = DecodePlanner.open_options_for(request, format, {3200, 800}, false, false)

      assert actual == expected,
             "mismatch for #{format}: #{inspect(actual)} != #{inspect(expected)}"
    end

    # And it genuinely differs from the unswapped arm: min(800/200, 3200/50) = 4
    # (shrink 4) vs. min(3200/200, 800/50) = 16 (shrink 8).
    assert DecodePlanner.open_options_for(request, :jpeg, {3200, 800})[:shrink] == 4

    assert DecodePlanner.open_options_for(%Request{resize_target: {200, 50}}, :jpeg, {3200, 800})[
             :shrink
           ] == 8
  end

  test "an EXIF quarter turn and a user quarter turn cancel to no swap" do
    # The `exif_5_cover_rot90` regression shape: EXIF 5/6/7/8 (90) + rot:90 =
    # net 180, which does NOT transpose the displayed axes. XOR gives false;
    # reading the EXIF term alone would wrongly swap.
    assert {:ok, rotate} = Operation.rotate(90)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, {:px, 50})
    chain = [rotate, resize]

    request = %Request{resize_target: {200, 50}, user_quarter_turn?: true}

    for format <- @formats do
      expected = chain_options(chain, format, {3200, 800}, true, true)
      actual = DecodePlanner.open_options_for(request, format, {3200, 800}, true, true)

      assert actual == expected,
             "mismatch for #{format}: #{inspect(actual)} != #{inspect(expected)}"
    end

    # No swap -> shrink against {3200, 800}: min(3200/200, 800/50) = 16 -> 8.
    assert DecodePlanner.open_options_for(request, :jpeg, {3200, 800}, true, true)[:shrink] == 8
  end

  # --- trim? disables shrink ---

  test "trim? true disables shrink even when resize_target is present" do
    request = %Request{trim?: true, resize_target: {400, 300}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  # --- Terminal-aware shrink (#377) ---

  test "terminal_reduction alone informs load shrink" do
    # 3200x2400 jpeg with only a {32,32} terminal frame (e.g. /output=blurhash,
    # no resize) -> ratio = min(3200/32, 2400/32) = 75 -> quantized shrink 8.
    request = %Request{terminal_reduction: {32, 32}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    assert opts[:shrink] == 8
  end

  test "resize_target governs over terminal_reduction when both are present" do
    request = %Request{resize_target: {800, 600}, terminal_reduction: {32, 32}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    # resize ratio = min(3200/800, 2400/600) = 4, not the terminal's 75/8.
    assert opts[:shrink] == 4
  end

  # --- required_extent is an independent floor ---

  test "required_extent caps a deeper shrink chosen by terminal_reduction" do
    # terminal hint alone wants shrink 8 (see above), but a 1600x1200 floor only
    # allows shrink 2 (3200/1600 = 2400/1200 = 2).
    request = %Request{terminal_reduction: {32, 32}, required_extent: {1600, 1200}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    assert opts[:shrink] == 2
  end

  test "required_extent caps a deeper shrink chosen by resize_target" do
    request = %Request{resize_target: {100, 100}, required_extent: {1600, 1200}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    assert opts[:shrink] == 2
  end

  test "required_extent below the natural shrink has no effect" do
    request = %Request{resize_target: {800, 600}, required_extent: {100, 100}}
    opts = DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})

    assert opts[:shrink] == 4
  end

  # --- No inputs -> no shrink from those inputs ---

  test "an empty request produces no shrink or scale keys" do
    for format <- @formats do
      opts = DecodePlanner.open_options_for(%Request{}, format, {3200, 2400})

      refute Keyword.has_key?(opts, :shrink)
      refute Keyword.has_key?(opts, :scale)
      assert opts[:access] == :sequential
      assert opts[:fail_on] == :error
    end
  end
end

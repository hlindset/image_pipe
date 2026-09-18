defmodule ImagePipe.Transform.DecodePlannerRequestTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.DecodePlanner.Request

  @formats [:jpeg, :webp, :png]

  test "resize_target and crop_extent produce format-specific load options" do
    # src 3200x2400; crop 1600x1200 feeds a fit:400x300 resize (no dpr/zoom) ->
    # crop/target ratio = min(1600/400, 1200/300) = 4.
    request = %Request{resize_target: {400, 300}, crop_extent: {1600, 1200}}
    assert DecodePlanner.open_options_for(request, :jpeg, {3200, 2400})[:shrink] == 4
    assert DecodePlanner.open_options_for(request, :webp, {3200, 2400})[:scale] == 0.25

    png = DecodePlanner.open_options_for(request, :png, {3200, 2400})
    refute Keyword.has_key?(png, :shrink)
    refute Keyword.has_key?(png, :scale)
  end

  test "resize_target axis swap changes the governing ratio" do
    # src 3200x800 (landscape); an asymmetric target (200x50) makes the swap change
    # which axis governs the min(), so the two quarter-turn settings genuinely
    # diverge, and both entry points must diverge identically.
    request = %Request{resize_target: {200, 50}}

    assert DecodePlanner.open_options_for(request, :jpeg, {3200, 800})[:shrink] == 8
    assert DecodePlanner.open_options_for(request, :jpeg, {3200, 800}, true, true)[:shrink] == 4
  end

  # --- user_quarter_turn? XORs with the EXIF turn ---

  test "user_quarter_turn? swaps the shrink axes when there is no EXIF turn" do
    # src 3200x800; a rot:90 before a fit:200x50 resize means the target's axes
    # are the stored axes swapped -> shrink computed against {800, 3200}.
    request = %Request{resize_target: {200, 50}, user_quarter_turn?: true}

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
    request = %Request{resize_target: {200, 50}, user_quarter_turn?: true}

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

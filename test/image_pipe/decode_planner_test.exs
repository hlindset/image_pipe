defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.DecodePlanner

  # A semantic operation chain reaches the planner through
  # `request_from_chain/3`; `exif_quarter_turn?` there is the NET EXIF turn,
  # already gated by the caller's auto-rotate policy.
  defp chain_options(chain, format, dims, exif_quarter_turn? \\ false, auto_rotate? \\ false) do
    chain
    |> DecodePlanner.request_from_chain(dims, exif_quarter_turn? and auto_rotate?)
    |> DecodePlanner.open_options_for(format, dims, exif_quarter_turn?, auto_rotate?)
  end

  # --- Access (always :sequential) ---

  test "empty chain opens sequentially with fail_on error regardless of format" do
    opts = chain_options([], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  test "width-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, :auto)
    opts = chain_options([resize], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  test "height-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 120})
    opts = chain_options([resize], :jpeg, {2000, 3000})
    assert opts[:access] == :sequential
  end

  test "a point-effect op is access-neutral (alone: sequential; with rotate: sequential)" do
    {:ok, blur} = Operation.blur(2.0)

    neutral_only = chain_options([blur], :png, {100, 100})

    assert neutral_only[:access] == :sequential

    {:ok, rotate} = Operation.rotate(180)

    with_sequential = chain_options([rotate, blur], :png, {100, 100})

    assert with_sequential[:access] == :sequential
  end

  test "crops open sequentially" do
    assert {:ok, crop} = Operation.crop_guided({:px, 80}, {:px, 80}, :center)
    opts = chain_options([crop], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  # --- JPEG shrink-on-load ---

  test "JPEG shrink is quantized to largest power of 2 not exceeding load_shrink" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)

    # src_w=3200, target_w=400 → load_shrink=8.0 → shrink 8
    opts8 = chain_options([resize], :jpeg, {3200, 2400})
    assert opts8[:shrink] == 8

    # src_w=3000, target_w=400 → load_shrink=7.5 → shrink 4 (not 8)
    opts4 = chain_options([resize], :jpeg, {3000, 2000})
    assert opts4[:shrink] == 4

    # src_w=1000, target_w=400 → load_shrink=2.5 → shrink 2
    opts2 = chain_options([resize], :jpeg, {1000, 800})
    assert opts2[:shrink] == 2

    # src_w=600, target_w=400 → load_shrink=1.5 → shrink 1 (no shrink key)
    opts1 = chain_options([resize], :jpeg, {600, 400})
    refute Keyword.has_key?(opts1, :shrink)
    refute Keyword.has_key?(opts1, :scale)
  end

  test "JPEG shrink uses min(wshrink, hshrink) to avoid over-shrinking" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 600})
    # src={3200,2400}, target={400,600} → wshrink=8, hshrink=4 → min=4
    opts = chain_options([resize], :jpeg, {3200, 2400})
    assert opts[:shrink] == 4
  end

  test "JPEG width-only resize uses wshrink only (no hshrink constraint)" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto)
    # src_w=1600 → wshrink=16 → capped at 8
    opts = chain_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 8
  end

  test "JPEG height-only resize uses hshrink only" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 100})
    # src_h=1600 → hshrink=16 → capped at 8
    opts = chain_options([resize], :jpeg, {1200, 1600})
    assert opts[:shrink] == 8
  end

  test "JPEG cover-mode resize is also shrink-eligible" do
    assert {:ok, resize} = Operation.resize(:cover, {:px, 200}, {:px, 200})
    # src={1600,1200}, target={200,200} → wshrink=8, hshrink=6 → min=6 → shrink 4
    opts = chain_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 4
  end

  test "JPEG auto×auto resize emits no shrink" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, :auto)
    opts = chain_options([resize], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  test "JPEG shrink arithmetic operates on the dims it is handed" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    # 1200/400 = 3.0 → shrink 2
    opts = chain_options([resize], :jpeg, {1200, 800})
    assert opts[:shrink] == 2
  end

  test "EXIF quarter-turn swaps shrink axes only when auto_rotate AND exif_quarter_turn?" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    chain = [resize]

    # auto_rotate true + quarter-turn => swap => shrink on 800 width
    swapped = chain_options(chain, :jpeg, {3200, 800}, true, true)
    assert swapped[:shrink] == 2

    # auto_rotate false + quarter-turn => no swap => shrink on 3200
    no_ar = chain_options(chain, :jpeg, {3200, 800}, true, false)
    assert no_ar[:shrink] == 8

    # auto_rotate true + not quarter-turn => no swap
    not_qt = chain_options(chain, :jpeg, {3200, 800}, false, true)
    assert not_qt[:shrink] == 8
  end

  # --- WebP scale-on-load ---

  test "WebP gets fractional scale for large downscales" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, :auto)
    # src_w=1600, target=200 → load_shrink=8.0 → scale=1/8=0.125
    opts = chain_options([resize], :webp, {1600, 1200})
    assert_in_delta opts[:scale], 1.0 / 8.0, 0.001
    refute Keyword.has_key?(opts, :shrink)
  end

  test "WebP emits no scale when load_shrink <= 1" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 800}, :auto)
    opts = chain_options([resize], :webp, {600, 400})
    refute Keyword.has_key?(opts, :scale)
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Over-shrink guards: the load shrink must never decode below the target ---

  test "dpr inflates the shrink target so the decode is not over-shrunk" do
    # src_w 4000, w 444, dpr 3 -> effective target 1332 -> wshrink 3.0 -> shrink 2
    # (Without accounting for dpr this would be 4000/444 ≈ 9 -> shrink 8, decoding
    # 500px and forcing the residual resize to upscale to 1332.)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 444}, :auto, dpr: 3, enlargement: :allow)
    opts = chain_options([resize], :jpeg, {4000, 2667})
    assert opts[:shrink] == 2
  end

  test "zoom inflates the shrink target so the decode is not over-shrunk" do
    # src_w 4000, w 200, zoom 4 -> effective target 800 -> wshrink 5.0 -> shrink 4
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, :auto, zoom_x: 4.0, zoom_y: 4.0)
    opts = chain_options([resize], :jpeg, {4000, 2667})
    assert opts[:shrink] == 4
  end

  test "min_width/min_height disable shrink (they enlarge to a floor, not a simple multiplier)" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto, min_width: {:px, 2000})
    opts = chain_options([resize], :jpeg, {4000, 2667})
    refute Keyword.has_key?(opts, :shrink)
  end

  test "a crop before the resize disables shrink (cropped working set, not full source)" do
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 600}, {:px, 600})
    assert {:ok, resize} = Operation.resize(:fit, {:px, 500}, {:px, 500})
    opts = chain_options([crop, resize], :jpeg, {4000, 2667})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "a quarter-turn user rotate before the resize shrinks with the axes swapped (#151)" do
    # Stored 3200×800 (landscape); a user rot:90 displays it portrait (800×3200), so
    # a width-only fit:400 targets the displayed width 800. With the swap the shrink
    # is computed on 800/400 = 2 → shrink 2. Without the swap it would be 3200/400 = 8.
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)

    for angle <- [90, 270] do
      assert {:ok, rotate} = Operation.rotate(angle)
      opts = chain_options([rotate, resize], :jpeg, {3200, 800})

      assert opts[:shrink] == 2,
             "user rotate #{angle} before resize must shrink with swapped axes"
    end
  end

  test "a rotate AFTER the resize contributes no turn (the IIIF operation order)" do
    # Same stored dims and resize target as the rotate-BEFORE-resize case above,
    # but with the rotate moved after the resize — the shape IIIF's canonical
    # `region_ops ++ size_ops ++ rotation_ops` order always produces. The rotate
    # reaches the chain too late to swap the shrink axes: shrink is 3200/400 = 8,
    # not the swapped 800/400 = 2 the same rotate produces before the resize.
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    assert {:ok, rotate} = Operation.rotate(90)
    opts = chain_options([resize, rotate], :jpeg, {3200, 800})
    assert opts[:shrink] == 8
  end

  test "a 180 user rotate before the resize shrinks without swapping the axes (#151)" do
    assert {:ok, rotate} = Operation.rotate(180)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    opts = chain_options([rotate, resize], :jpeg, {3200, 2400})
    assert opts[:shrink] == 8
  end

  test "combined EXIF + user rotate determines the swap by net turn (#151)" do
    # Stored 3200×800; width-only target fit:400. The swap fires iff the NET turn
    # (EXIF quarter ∘ user rotate) is a quarter turn, mirroring imgproxy
    # ExtractGeometry's `(angle + baseAngle) % 180`.
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)

    # EXIF quarter (auto_rotate) + user 90 = net 180 → NO swap → shrink on 3200.
    assert {:ok, rot90} = Operation.rotate(90)

    net_180 =
      chain_options([rot90, resize], :jpeg, {3200, 800}, true, true)

    assert net_180[:shrink] == 8

    # EXIF quarter (auto_rotate) + user 180 = net 90 → swap → shrink on 800.
    assert {:ok, rot180} = Operation.rotate(180)

    net_90 =
      chain_options([rot180, resize], :jpeg, {3200, 800}, true, true)

    assert net_90[:shrink] == 2

    # EXIF quarter present but auto_rotate OFF + user 90 = net 90 → swap → shrink on 800.
    exif_ignored =
      chain_options([rot90, resize], :jpeg, {3200, 800}, true, false)

    assert exif_ignored[:shrink] == 2

    # Two user quarter turns cancel (net 0) with no EXIF → no swap → shrink on 3200.
    no_swap =
      chain_options([rot90, rot90, resize], :jpeg, {3200, 800}, false, false)

    assert no_swap[:shrink] == 8
  end

  test "a crop + quarter-turn rotate before the resize composes B1 and B2 (#151)" do
    # Crop narrows the extent feeding the resize (B1); a preceding user rotate swaps
    # the displayed axes (B2). Stored 4000×2667; rot:90 → displayed 2667×4000. A
    # 1200×1200 crop (display frame) feeds a fit:400 → crop dim 1200/400 = 3 → shrink 2.
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 1200}, {:px, 1200})
    assert {:ok, rotate} = Operation.rotate(90)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 400})
    opts = chain_options([rotate, crop, resize], :jpeg, {4000, 2667})
    assert opts[:shrink] == 2
  end

  test "a crop AFTER the resize (cover-style) does not disable shrink" do
    # cover is a single PlanResize that crops internally after resizing, so it is
    # not a crop-before-resize and remains shrink-eligible.
    assert {:ok, resize} = Operation.resize(:cover, {:px, 200}, {:px, 200})
    opts = chain_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 4
  end

  # --- Non-shrink-eligible formats ---

  test "PNG emits no shrink or scale regardless of target" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = chain_options([resize], :png, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  test "HEIF/AVIF emit no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    refute chain_options([resize], :heif, {3000, 2000}) |> Keyword.has_key?(:shrink)
    refute chain_options([resize], :avif, {3000, 2000}) |> Keyword.has_key?(:shrink)
  end

  test "unknown format emits no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = chain_options([resize], :some_unknown_format, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  # --- No-resize chain ---

  test "non-resize operations produce no shrink option for JPEG" do
    assert {:ok, blur} = Operation.blur(2.0)
    opts = chain_options([blur], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Legacy behavior: composition and effect operations ---

  test "composition operations open sequentially (no shrink for ops without resize)" do
    assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
    opts = chain_options([padding], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  # --- Trim blocks shrink-on-load ---

  test "a chain containing Trim blocks shrink-on-load" do
    assert {:ok, trim} = Operation.trim(threshold: 10.0, background: :auto)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, {:px, 100})
    chain = [trim, resize]

    opts = chain_options(chain, :jpeg, {800, 800})

    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "the same resize without Trim does shrink-on-load" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, {:px, 100})
    opts = chain_options([resize], :jpeg, {800, 800})
    assert Keyword.get(opts, :shrink) >= 2
  end
end

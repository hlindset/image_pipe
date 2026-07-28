defmodule ImagePipe.Transform.ExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage

  describe "fixed neutral execution" do
    test "a Plan executes through the fixed neutral driver" do
      assert {:ok, blur} = Operation.blur(1.0)

      assert {:ok, %State{} = state} =
               Executor.execute(plan([blur]), state_with_image(30, 20), [])

      assert dimensions(state.image) == {30, 20}
    end
  end

  describe "preamble gates" do
    # The colour preamble and the EXIF-orientation seed answer different
    # questions, so they take separate gates. A caller whose orientation was
    # already seeded before execution (the decode bracket does this) still needs
    # the colour import, and must not have its pending orientation re-derived.
    test "seed_input_color_management runs the colour preamble without seeding orientation" do
      image = profiled_image_with_orientation(80, 40, 6)
      plan = %{plan([]) | auto_rotate: true}

      assert {:ok, %State{} = conditioned} =
               Executor.execute(plan, %State{image: image},
                 seed_input_color_management: true,
                 seed_orientation: false
               )

      assert conditioned.color_imported? == true
      assert is_binary(conditioned.source_color_profile)
      # Orientation 6 is a quarter turn: had it been seeded, the boundary flush
      # would have swapped the axes.
      assert dimensions(conditioned.image) == {80, 40}

      # Control: the orientation gate on its own does seed, and the flush swaps.
      assert {:ok, %State{} = oriented} =
               Executor.execute(plan, %State{image: image}, seed_orientation: true)

      assert dimensions(oriented.image) == {40, 80}
    end
  end

  describe "resize execution" do
    test "resize fit, cover, and stretch execute through existing visible behavior" do
      cases = [
        {:fit, {:px, 100}, {:px, 100}, {300, 200}, {100, 67}},
        {:cover, {:px, 100}, {:px, 50}, {300, 200}, {100, 50}},
        {:stretch, :auto, {:px, 100}, {300, 200}, {300, 100}}
      ]

      for {mode, width, height, source_dimensions, expected_dimensions} <- cases do
        assert {:ok, operation} = Operation.resize(mode, width, height, enlargement: :allow)

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(
                   plan([operation]),
                   state_with_image(source_dimensions),
                   []
                 )

        assert dimensions(state.image) == expected_dimensions
      end
    end

    test "resize cover crops to the literal requested box when mw/mh exceed the target (#236)" do
      assert {:ok, operation} =
               Operation.resize(:cover, {:px, 200}, {:px, 200},
                 min_width: {:px, 400},
                 min_height: {:px, 400},
                 enlargement: :deny
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image({1600, 1200}),
                 []
               )

      assert dimensions(state.image) == {200, 200}
    end

    test "resize cover applies offsets to the result crop" do
      assert {:ok, operation} =
               Operation.resize(:cover, {:px, 100}, {:px, 100},
                 enlargement: :allow,
                 guide: {:anchor, :left, :center},
                 x_offset: {:pixels, 200}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_wide_offset_image(),
                 []
               )

      assert dimensions(state.image) == {100, 100}
      assert Image.get_pixel!(state.image, 50, 50) == [0, 0, 255]
    end
  end

  # Structural guardrail against this codebase's recurring bug shape: a result-crop
  # box (or a resize-derived cap) computed correctly on one mode/path and silently
  # skipped on its siblings — #236 was exactly "#194's result_box_* crop wired for
  # :fit, never :cover". A table over EVERY box-cropping mode catches the next
  # sibling at authoring time instead of months later via a differential probe.
  describe "cross-mode result-crop invariants (regression guardrails)" do
    # imgproxy's universal cropToResult crops to TargetWidth/Height = the LITERAL
    # requested box (Scale(po.Width, DprScale·Zoom)), NOT the min-expanded target.
    # So when mw/mh drive the scale past the requested box on both axes, every mode
    # that crops to a box trims back to that box. A mode that regressed to cropping
    # at the min-expanded target would land at 400×400 (or its cover intermediate).
    # :stretch is excluded — force has no cropToResult; it resizes straight to the
    # (min-expanded) target. A new box-cropping mode must be added to this list.
    test "mw/mh above the requested box trims to that box across box-cropping modes (#194/#236)" do
      for mode <- [:fit, :cover, :auto] do
        assert {:ok, operation} =
                 Operation.resize(mode, {:px, 200}, {:px, 200},
                   min_width: {:px, 400},
                   min_height: {:px, 400},
                   enlargement: :deny
                 )

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(plan([operation]), state_with_image({1600, 1200}), [])

        assert dimensions(state.image) == {200, 200},
               "#{mode}: result-crop should trim to the requested 200×200, " <>
                 "got #{inspect(dimensions(state.image))}"
      end
    end
  end

  describe "crop execution" do
    test "crop guided executes gravity crop against the current image" do
      assert {:ok, operation} = Operation.crop_guided({:px, 120}, {:px, 80}, :bottom_right)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(300, 200),
                 []
               )

      assert dimensions(state.image) == {120, 80}
    end

    test "crop region ratios resolve against actual current dimensions" do
      assert {:ok, resize} =
               Operation.resize(:stretch, {:px, 400}, {:px, 300}, enlargement: :allow)

      assert {:ok, crop} =
               Operation.crop_region(
                 {:ratio, 1, 4},
                 {:ratio, 1, 3},
                 {:ratio, 1, 2},
                 {:ratio, 1, 3}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([resize, crop]),
                 state_with_image(800, 600),
                 []
               )

      assert dimensions(state.image) == {200, 100}
    end
  end

  describe "canvas execution" do
    test "canvas supports pixel and auto geometry" do
      assert {:ok, operation} = Operation.canvas({:px, 120}, :auto, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(100, 50),
                 []
               )

      assert dimensions(state.image) == {120, 50}
    end

    test "canvas supports ratio geometry" do
      assert {:ok, operation} = Operation.canvas({:ratio, 4, 3}, {:ratio, 1, 1}, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(100, 100),
                 []
               )

      assert dimensions(state.image) == {133, 100}
    end
  end

  describe "composition execution" do
    test "padding expands dimensions and places the source image by left and top" do
      assert {:ok, padding} =
               Operation.padding({:px, 1}, {:px, 2}, {:px, 3}, {:px, 4})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_split_image(), [])

      assert dimensions(state.image) == {8, 5}
      assert rgb_pixel(state.image, 4, 1) == [255, 0, 0]
      assert rgb_pixel(state.image, 5, 1) == [0, 0, 255]
    end

    test "padding scales sides with round-half-to-even" do
      assert {:ok, padding} =
               Operation.padding({:px, 1}, {:px, 3}, {:px, 5}, {:px, 7},
                 pixel_ratio: {:ratio, 1, 2}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(10, 10), [])

      assert dimensions(state.image) == {16, 12}
    end

    test "transparent padding over an RGB source preserves alpha in generated pixels" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(2, 2), [])

      assert alpha_value(state.image, 0, 0) == 0
    end

    test "opaque background composites transparent generated pixels without changing dimensions" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, background} = Operation.background(red)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding, background]), state_with_image(2, 2), [])

      assert dimensions(state.image) == {3, 3}
      assert rgb_pixel(state.image, 0, 0) == [255, 0, 0]
      assert is_nil(Enum.at(Image.get_pixel!(state.image, 0, 0), 3))
    end

    test "alpha background preserves output alpha for alpha-capable encoders" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})
      assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})
      assert {:ok, background} = Operation.background(red)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding, background]), state_with_image(2, 2), [])

      assert dimensions(state.image) == {3, 3}
      assert Image.get_pixel!(state.image, 0, 0) == [255, 0, 0, 128]
    end

    test "transparent canvas over an RGB source preserves alpha in generated pixels" do
      assert {:ok, canvas} = Operation.canvas({:px, 4}, {:px, 4}, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([canvas]), state_with_image(2, 2), [])

      assert alpha_value(state.image, 0, 0) == 0
    end

    test "alpha solid canvas fill preserves alpha in generated pixels" do
      assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})
      assert {:ok, canvas} = Operation.canvas({:px, 4}, {:px, 4}, :center, fill: {:solid, red})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([canvas]), state_with_image(2, 2), [])

      assert Image.get_pixel!(state.image, 0, 0) == [255, 0, 0, 128]
    end

    test "padding after resize keeps explicit pixel ratio authoritative" do
      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 1000}, :auto, dpr: 2.0, enlargement: :deny)

      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:ratio, 2, 1}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([resize, padding]), state_with_image(100, 50), [])

      assert dimensions(state.image) == {100, 70}
    end

    test "padding without a preceding resize uses requested pixel ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:ratio, 2, 1}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(100, 50), [])

      assert dimensions(state.image) == {100, 70}
    end
  end

  describe "multi-pipeline plan execution" do
    test "materialized? threads from pipeline 1 into pipeline 2" do
      pipeline1 = %Pipeline{operations: [%Rotate{angle: 90}]}
      pipeline2 = %Pipeline{operations: [%Rotate{angle: 90}]}

      multi_plan = %Plan{
        source: %Source.Path{segments: ["images", "cat.jpg"]},
        pipelines: [pipeline1, pipeline2],
        output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
      }

      assert {:ok, %State{} = state} =
               Transform.execute_plan(multi_plan, state_with_image(40, 20), [])

      assert state.materialized? == true
      assert Image.width(state.image) == 40
      assert Image.height(state.image) == 20
    end
  end

  describe "orientation primitives" do
    # source_dimensions storage-frame invariant: under deferred orientation,
    # source_dimensions stays in the STORED (pre-rotation) frame — it is NOT
    # swapped by any pre-resize op. A resize that follows a pending 90° rotate
    # sizes against the stored dims and consumes/clears source_dimensions.
    # This replaces the deleted AutoOrient in-step swap coverage from T10.
    test "source_dimensions stays in the storage frame under a pending quarter-turn" do
      {:ok, rotate} = Operation.rotate(90)
      # fit resize targeting the stored width (80px).
      # If source_dimensions were swapped to display dims {40, 80}, the resize
      # would compute against 40 wide and produce a different result.
      {:ok, resize} = Operation.resize(:fit, {:px, 40}, :auto, enlargement: :deny)

      # source is a shrunk 80×40 image; the original stored dims are {160, 80}.
      # The fit resize to {:px, 40} against source_dimensions {160, 80}
      # sizes at scale 0.25, so 80×40 → 40×20 (half of the loaded image).
      {:ok, image} = Image.new(80, 40, color: :white)

      state_with_shrink_dims = %State{
        image: image,
        source_dimensions: {160, 80}
      }

      assert {:ok, %State{} = result} =
               Transform.execute_plan(
                 plan([rotate, resize]),
                 state_with_shrink_dims,
                 []
               )

      # The residual resize consumes and clears source_dimensions.
      assert result.source_dimensions == nil
      # After the flush the orientation is rotated 90°, so the final image is
      # portrait (height > width from the 40×20 pre-flush result → 20×40 after 90°).
      assert Image.height(result.image) > Image.width(result.image)
    end

    # #185: decode_shrink is a STORAGE-frame per-axis factor; a gravity crop is
    # authored in the DISPLAY frame and `compensate_crop` swaps its axes after the
    # decode-shrink rescale under a quarter turn. The per-axis factors must therefore
    # be swapped before the rescale, or each display axis is divided by the wrong
    # storage factor. Real shrink-on-load is uniform (w≈h), so this is only
    # observable with asymmetric factors — set them directly, as the storage-frame
    # test above sets source_dimensions.
    #
    # Display request 80×60 with decode_shrink {w: 2, h: 4} under a 90° turn:
    # display width→storage height (h factor 4), display height→storage width
    # (w factor 2) ⇒ storage crop (60/2)×(80/4) = 30×20, which the post-crop flush
    # rotates to a 20×30 display frame. Pre-fix the un-swapped factors give storage
    # 15×40 → display 40×15.
    test "decode_shrink per-axis factors swap for a quarter-turn gravity crop" do
      {:ok, rotate} = Operation.rotate(90)
      {:ok, crop} = Operation.crop_guided({:px, 80}, {:px, 60}, :center)

      {:ok, image} = Image.new(200, 200, color: :white)
      state = %State{image: image, decode_shrink: %{w: 2.0, h: 4.0}}

      assert {:ok, %State{} = result} =
               Transform.execute_plan(plan([rotate, crop]), state, [])

      assert {Image.width(result.image), Image.height(result.image)} == {20, 30}
    end

    # Region-crop variant of the above. A CropRegion authored in the display frame
    # flushes the pending orientation first, then crops the oriented frame while
    # decode_shrink is still set — so it needs the same per-axis swap: after a
    # quarter-turn flush the display width axis came from the storage height axis (and
    # vice versa), so a display dimension is divided by the factor of the storage axis
    # it came from. CropRegion is product-neutral surface (no imgproxy region crop);
    # this keeps it correct for any future parser that emits it.
    #
    # Display region 80×60 with decode_shrink {w: 2, h: 4} under a 90° turn ⇒ crop
    # 80/4 × 60/2 = 20×30 on the flushed frame. Pre-fix the un-swapped factors give
    # 80/2 × 60/4 = 40×15.
    test "decode_shrink per-axis factors swap for a quarter-turn region crop" do
      {:ok, rotate} = Operation.rotate(90)
      {:ok, crop} = Operation.crop_region({:px, 40}, {:px, 40}, {:px, 80}, {:px, 60})

      {:ok, image} = Image.new(200, 200, color: :white)
      state = %State{image: image, decode_shrink: %{w: 2.0, h: 4.0}}

      assert {:ok, %State{} = result} =
               Transform.execute_plan(plan([rotate, crop]), state, [])

      assert {Image.width(result.image), Image.height(result.image)} == {20, 30}
    end

    test "user rotate folds into deferred orientation and flushes at the pipeline boundary" do
      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%Rotate{angle: 90}]),
                 state_with_image(80, 40),
                 []
               )

      assert dimensions(state.image) == {40, 80}
    end

    test "user flip folds into deferred orientation and flushes at the pipeline boundary" do
      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%Flip{axis: :horizontal}]),
                 state_with_split_image(),
                 []
               )

      assert Image.get_pixel!(state.image, 0, 0) == [0, 0, 255]
      assert Image.get_pixel!(state.image, 1, 0) == [255, 0, 0]
    end
  end

  describe "effect execution" do
    test "blur softens hard color boundaries without changing dimensions" do
      assert {:ok, blur} = Operation.blur(2.0)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([blur]), state_with_split_image(), [])

      assert dimensions(state.image) == {2, 1}
      assert rgb_pixel(state.image, 0, 0) != [255, 0, 0]
      assert rgb_pixel(state.image, 1, 0) != [0, 0, 255]
    end

    test "sharpen preserves dimensions" do
      assert {:ok, sharpen} = Operation.sharpen(1.0)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([sharpen]), state_with_image(20, 20), [])

      assert dimensions(state.image) == {20, 20}
    end

    test "pixelate groups pixels using the requested block size" do
      assert {:ok, pixelate} = Operation.pixelate(2)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([pixelate]), state_with_striped_image(), [])

      assert dimensions(state.image) == {4, 2}
      assert rgb_pixel(state.image, 0, 0) == rgb_pixel(state.image, 1, 0)
      assert rgb_pixel(state.image, 2, 0) == rgb_pixel(state.image, 3, 0)
    end

    test "pixelate preserves dimensions for non-divisible and oversized block sizes" do
      assert {:ok, non_divisible} = Operation.pixelate(2)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([non_divisible]), state_with_image(5, 3), [])

      assert dimensions(state.image) == {5, 3}

      assert {:ok, oversized} = Operation.pixelate(100)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([oversized]), state_with_image(10, 10), [])

      assert dimensions(state.image) == {10, 10}
    end

    test "pixelate uses a box mean that cannot overshoot the source range (#238)" do
      # Sharp blue/gold vertical edge. imgproxy pixelates with vips_shrink (a pure
      # box mean) + vips_zoom (nearest), so every block value is bounded by the
      # source's [min_in, max_in] per band. libvips' default Lanczos resize kernel
      # has negative lobes that ring at the edge and overshoot outside that range
      # (the #238 halo) — values darker than the blue and brighter than the gold.
      blue = [40, 40, 200]
      gold = [200, 180, 60]
      lo = [40, 40, 60]
      hi = [200, 180, 200]

      image =
        20
        |> Image.new!(10, color: gold)
        |> Image.Draw.rect!(0, 0, 10, 10, color: blue)

      assert {:ok, pixelate} = Operation.pixelate(7)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([pixelate]), %State{image: image}, [])

      for x <- 0..(Image.width(state.image) - 1),
          y <- 0..(Image.height(state.image) - 1),
          {value, band} <- Enum.with_index(rgb_pixel(state.image, x, y)) do
        assert value >= Enum.at(lo, band) and value <= Enum.at(hi, band),
               "(#{x},#{y}) band #{band}=#{value} outside [#{Enum.at(lo, band)}, #{Enum.at(hi, band)}]"
      end
    end

    test "brightness contrast and saturation preserve dimensions and change pixels" do
      baseline = state_with_adjustment_image()

      for build_operation <- [
            &Operation.brightness/1,
            &Operation.contrast/1,
            &Operation.saturation/1
          ] do
        assert {:ok, operation} = build_operation.(25)

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(plan([operation]), state_with_adjustment_image(), [])

        assert dimensions(state.image) == dimensions(baseline.image)
        assert rgb_pixel(state.image, 0, 0) != rgb_pixel(baseline.image, 0, 0)
      end
    end

    test "monochrome and duotone preserve dimensions and change pixels" do
      baseline = state_with_adjustment_image()
      assert {:ok, tint} = Operation.color(255, 204, 0)
      assert {:ok, shadow} = Operation.color(17, 34, 51)
      assert {:ok, highlight} = Operation.color(255, 238, 204)

      for operation <- [
            Operation.monochrome({:ratio, 1, 1}, tint),
            Operation.duotone({:ratio, 1, 1}, shadow, highlight)
          ] do
        assert {:ok, operation} = operation

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(plan([operation]), state_with_adjustment_image(), [])

        assert dimensions(state.image) == dimensions(baseline.image)
        assert rgb_pixel(state.image, 0, 0) != rgb_pixel(baseline.image, 0, 0)
      end
    end
  end

  test "resize auto executes against current image state" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)

    state = state_with_image(1600, 900)

    assert {:ok, %State{} = state} =
             Transform.execute_plan(plan([operation]), state, [])

    assert dimensions(state.image) == {300, 200}
  end

  for {source, target, expected_dimensions, visible_crop?} <- [
        {{1600, 900}, {300, 200}, {300, 200}, true},
        {{1600, 900}, {200, 300}, {200, 113}, false},
        {{1000, 1000}, {300, 300}, {300, 300}, false},
        # #233: square source into a landscape target shares the non-negative bucket
        # (src_d == 0, dst_d > 0), so auto fills (cover) to {300, 200} rather than fitting
        # to {200, 200}.
        {{1000, 1000}, {300, 200}, {300, 200}, false}
      ] do
    test "resize auto #{inspect(source)} to #{inspect(target)} returns #{inspect(expected_dimensions)}" do
      source = unquote(Macro.escape(source))
      {target_width, target_height} = unquote(Macro.escape(target))
      expected_dimensions = unquote(Macro.escape(expected_dimensions))
      visible_crop? = unquote(visible_crop?)

      assert {:ok, operation} =
               Operation.resize(:auto, {:px, target_width}, {:px, target_height},
                 enlargement: :allow
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_resize_auto_source(source),
                 []
               )

      assert dimensions(state.image) == expected_dimensions
      assert_resize_auto_visible_crop(visible_crop?, state.image)
    end
  end

  test "ordered resize then ratio crop uses actual post-resize dimensions" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 300}, {:px, 200}, enlargement: :deny)

    assert {:ok, crop} =
             Operation.crop_region(
               {:ratio, 1, 10},
               {:ratio, 1, 10},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([resize, crop]),
               state_with_image(600, 400),
               []
             )

    assert dimensions(state.image) == {150, 100}
  end

  test "resize auto observes dimensions changed by earlier operations" do
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 200}, {:px, 400})
    assert {:ok, resize} = Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([crop, resize]),
               state_with_image(600, 400),
               []
             )

    assert dimensions(state.image) == {100, 200}
  end

  test "resize auto cover branch applies offsets to the result crop" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 50},
               enlargement: :allow,
               guide: {:anchor, :left, :center},
               x_offset: {:pixels, 50}
             )

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([operation]),
               state_with_wide_offset_image(),
               []
             )

    assert dimensions(state.image) == {100, 50}
    assert Image.get_pixel!(state.image, 75, 25) == [0, 0, 255]
  end

  test "chained resize with a percent second op resolves against the running width" do
    {:ok, image} = Image.new(400, 300)
    state = %State{image: image}

    {:ok, first} = Operation.resize(:fit, {:px, 340}, :auto, enlargement: :allow)
    {:ok, second} = Operation.resize(:fit, {:percent, 50}, :auto, enlargement: :allow)

    plan = %Plan{
      source: %Source.Path{segments: ["x"]},
      pipelines: [%Pipeline{operations: [first, second]}],
      output: %ImagePipe.Plan.Output{mode: :automatic}
    }

    {:ok, %State{image: result}} = Executor.execute(plan, state, [])

    assert Image.width(result) == 170
  end

  describe "CropRegion out-of-bounds verdict decided in the original source frame" do
    # A post-decode state where shrink-on-load decoded a 200×300 source to 100×150
    # (decode_shrink 2.0). effective_source_dims reports the ORIGINAL 200×300, which is
    # the frame the wholly-outside decision must use.
    defp shrunk_source_state do
      {:ok, image} = Image.new(100, 150, color: :white)
      %State{image: image, source_dimensions: {200, 300}, decode_shrink: %{w: 2.0, h: 2.0}}
    end

    test "a near-far-edge partial overlap is NOT rejected under shrink-on-load" do
      # x=199 is in-bounds at full res (199 < 200 → 1px overlap → clip). The coordinate
      # rescale rounds round(199/2)=100, equal to the shrunk width 100 — deciding in the
      # shrunk frame would spuriously 400. Deciding in the original frame keeps it a clip.
      {:ok, region} =
        Operation.crop_region({:px, 199}, {:px, 10}, {:px, 100}, {:px, 100},
          on_out_of_bounds: :reject
        )

      assert {:ok, %State{}} =
               Transform.execute_plan(plan([region]), shrunk_source_state(), [])
    end

    test "a wholly-outside origin IS rejected under shrink-on-load" do
      {:ok, region} =
        Operation.crop_region({:px, 250}, {:px, 10}, {:px, 100}, {:px, 100},
          on_out_of_bounds: :reject
        )

      assert {:error, {:transform_error, {:bad_request, :region_out_of_bounds}}} =
               Transform.execute_plan(plan([region]), shrunk_source_state(), [])
    end
  end

  defp plan(operations) do
    %Plan{
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp state_with_image({width, height}), do: state_with_image(width, height)

  defp state_with_image(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp state_with_split_image do
    image =
      2
      |> Image.new!(1, color: :black)
      |> Image.Draw.rect!(0, 0, 1, 1, color: :red)
      |> Image.Draw.rect!(1, 0, 1, 1, color: :blue)

    %State{image: image}
  end

  # A non-square image carrying both an importable embedded profile (borrowed
  # from the committed wide-gamut fixture) and an EXIF orientation tag, so one
  # run can observe the colour import and the orientation seed independently.
  defp profiled_image_with_orientation(width, height, orientation) do
    {:ok, profile} =
      "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"
      |> Image.open!(access: :sequential)
      |> VipsImage.header_value("icc-profile-data")

    {:ok, image} =
      width
      |> Image.new!(height, color: [120, 60, 200])
      |> VipsImage.mutate(fn mutable ->
        :ok = MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
        :ok = MutableImage.set(mutable, "orientation", :gint, orientation)
      end)

    image
  end

  defp state_with_striped_image do
    image =
      4
      |> Image.new!(2, color: :black)
      |> Image.Draw.rect!(0, 0, 1, 2, color: :red)
      |> Image.Draw.rect!(1, 0, 1, 2, color: :green)
      |> Image.Draw.rect!(2, 0, 1, 2, color: :blue)
      |> Image.Draw.rect!(3, 0, 1, 2, color: :white)

    %State{image: image}
  end

  defp state_with_adjustment_image do
    image =
      2
      |> Image.new!(1, color: [128, 96, 64])
      |> Image.Draw.rect!(1, 0, 1, 1, color: [64, 96, 128])

    %State{image: image}
  end

  defp state_with_wide_offset_image do
    image =
      300
      |> Image.new!(100, color: :red)
      |> Image.Draw.rect!(200, 0, 100, 100, color: :blue)

    %State{image: image}
  end

  defp state_with_resize_auto_source({1600, 900}) do
    image =
      1600
      |> Image.new!(900, color: :white)
      |> Image.Draw.rect!(0, 0, 90, 900, color: :red)
      |> Image.Draw.rect!(1510, 0, 90, 900, color: :blue)

    %State{image: image}
  end

  defp state_with_resize_auto_source(source), do: state_with_image(source)

  defp rgb_pixel(image, x, y) do
    image
    |> Image.get_pixel!(x, y)
    |> Enum.take(3)
  end

  defp alpha_value(image, x, y) do
    image
    |> Image.get_pixel!(x, y)
    |> Enum.at(3)
  end

  defp assert_resize_auto_visible_crop(true, image) do
    assert Image.get_pixel!(image, 0, div(Image.height(image), 2)) == [255, 255, 255]

    assert Image.get_pixel!(image, Image.width(image) - 1, div(Image.height(image), 2)) == [
             255,
             255,
             255
           ]
  end

  defp assert_resize_auto_visible_crop(false, _image), do: :ok

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
end

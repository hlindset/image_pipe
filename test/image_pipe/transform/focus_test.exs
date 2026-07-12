defmodule ImagePipe.Transform.FocusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  describe "rational helpers" do
    test "default carried point is nil and helpers no-op on nil" do
      assert Focus.scale(nil, {:ratio, 1, 2}, {:ratio, 1, 2}) == nil
      assert Focus.translate(nil, -10, -5) == nil
      assert Focus.to_fp(nil, 400, 400) == nil
    end

    test "scale multiplies each axis exactly (rational, no float)" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      scaled = Focus.scale(point, {:ratio, 1, 2}, {:ratio, 1, 2})
      assert scaled == {{:ratio, 100, 1}, {:ratio, 50, 1}}
    end

    test "translate subtracts/adds integer deltas exactly" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      assert Focus.translate(point, -40, -30) == {{:ratio, 160, 1}, {:ratio, 70, 1}}
      # transient negative numerator is allowed (a later canvas +x recovers it)
      assert Focus.translate(point, -300, 0) ==
               {{:ratio, -100, 1}, {:ratio, 100, 1}}
    end
  end

  describe "resolve/3 (set_focus directive unit resolution)" do
    # ctx/1: no orientation, no shrink (storage dims; display is derived internally).
    defp ctx(dims), do: %{storage: dims, decode_shrink: nil}
    defp ctx(dims, shrink), do: %{storage: dims, decode_shrink: shrink}

    test "resolves px against the live frame" do
      assert Focus.resolve({:coord, {:px, 20}, {:px, 10}}, ctx({400, 400}), nil) ==
               {{:ratio, 20, 1}, {:ratio, 10, 1}}
    end

    test "resolves a relative ratio against the live frame" do
      assert Focus.resolve({:coord, {:ratio, 1, 2}, {:ratio, 1, 4}}, ctx({400, 400}), nil) ==
               {{:ratio, 200, 1}, {:ratio, 100, 1}}
    end

    test "clamps positive OOB (px and relative >1) to the far edge (dim-1)" do
      assert Focus.resolve({:coord, {:px, 500}, {:px, 500}}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}

      assert Focus.resolve({:coord, {:ratio, 3, 2}, {:ratio, 3, 2}}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}
    end

    test "resolves anchors to corner/edge points" do
      assert Focus.resolve({:anchor, :left, :top}, ctx({400, 400}), nil) ==
               {{:ratio, 0, 1}, {:ratio, 0, 1}}

      assert Focus.resolve({:anchor, :right, :bottom}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}

      assert Focus.resolve({:anchor, :center, :center}, ctx({400, 400}), nil) ==
               {{:ratio, 200, 1}, {:ratio, 200, 1}}
    end

    test "bare-pixel focus rescales by decode_shrink; relative/anchor do not" do
      shrunk = ctx({100, 100}, %{w: 4.0, h: 4.0})

      assert Focus.resolve({:coord, {:px, 100}, {:px, 100}}, shrunk, nil) ==
               {{:ratio, 25, 1}, {:ratio, 25, 1}}

      assert Focus.resolve({:coord, {:ratio, 1, 2}, {:ratio, 1, 2}}, shrunk, nil) ==
               {{:ratio, 50, 1}, {:ratio, 50, 1}}
    end
  end

  describe "to_fp/1" do
    test "normalizes to a 0..1 fraction against the live image dims" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      assert {:fp, fx, fy} = Focus.to_fp(point, 400, 400)
      assert_in_delta fx, 0.5, 1.0e-9
      assert_in_delta fy, 0.25, 1.0e-9
    end

    test "clamps fp into [0,1]" do
      over = {{:ratio, 500, 1}, {:ratio, 500, 1}}
      assert Focus.to_fp(over, 400, 400) == {:fp, 1.0, 1.0}
      under = {{:ratio, -10, 1}, {:ratio, -10, 1}}
      assert Focus.to_fp(under, 400, 400) == {:fp, 0.0, 0.0}
    end
  end

  # ---- transform-level pixel-equivalence (probe-seeded) -------------------
  # A 4x4 colour grid where each cell's colour encodes its (col,row), mirroring
  # tools/twicpics_focus_probe.exs. Focus on a cell, run the geometry op(s),
  # then a tiny crop reading the *carried* focus, and decode which cell lands
  # in the centre.

  @cols 4
  @rows 4
  @cell 100

  defp grid do
    base = Image.new!(@cols * @cell, @rows * @cell, color: [0, 0, 0])

    for col <- 0..(@cols - 1), row <- 0..(@rows - 1), reduce: base do
      acc ->
        Image.compose!(acc, Image.new!(@cell, @cell, color: cell_color(col, row)),
          x: col * @cell,
          y: row * @cell
        )
    end
  end

  defp cell_color(col, row),
    do: [round(col * 255 / (@cols - 1)), round(row * 255 / (@rows - 1)), 255]

  defp nearest_cell([r, g, b]) do
    for(col <- 0..(@cols - 1), row <- 0..(@rows - 1), do: {col, row})
    |> Enum.min_by(fn {col, row} ->
      [cr, cg, cb] = cell_color(col, row)
      (cr - r) ** 2 + (cg - g) ** 2 + (cb - b) ** 2
    end)
  end

  # Build a full TwicPics plan from a manipulation chain and run it through
  # Executor on the grid, decoding the result's centre cell.
  defp plan_cell(chain) do
    {:ok, plan} =
      PlanBuilder.to_plan(%Source.Path{segments: ["x.png"]}, chain, ImagePipe.Config.resolve!([]))

    {:ok, state} = Executor.execute(plan, %State{image: grid()}, [])
    w = Image.width(state.image)
    h = Image.height(state.image)

    state.image
    |> Image.get_pixel!(div(w, 2), div(h, 2))
    |> Enum.take(3)
    |> Enum.map(&round/1)
    |> nearest_cell()
  end

  describe "set_focus directive executes through Executor" do
    test "focus=150x150/crop=12x12 steers to the focused cell via the full plan" do
      assert plan_cell([{"focus", "150x150"}, {"crop", "12x12"}]) == {1, 1}
    end
  end

  describe "0-based boundary round-trip and OOB (probe-seeded)" do
    test "the last pixel (399) lands on the bottom-right cell" do
      assert plan_cell([{"focus", "399x399"}, {"crop", "1x1"}]) == {3, 3}
    end

    test "a positive OOB px (500) clamps to the far edge -> bottom-right" do
      assert plan_cell([{"focus", "500x500"}, {"crop", "1x1"}]) == {3, 3}
    end

    test "a relative >100% focus (150p) clamps to the far edge -> bottom-right" do
      assert plan_cell([{"focus", "150px150p"}, {"crop", "1x1"}]) == {3, 3}
    end

    test "a cell-midpoint coordinate lands on its cell" do
      assert plan_cell([{"focus", "150x150"}, {"crop", "1x1"}]) == {1, 1}
    end

    test "an anchor focus carries as a point through a preceding resize" do
      # top-right anchor resolves to (399, 0) against the 400² frame, then carries
      # (scaled) through resize=50p; the trailing carried crop lands on cell (3,0).
      assert plan_cell([{"focus", "top-right"}, {"resize", "50p"}, {"crop", "1x1"}]) == {3, 0}
    end

    test "crop@coords resets the focus and recovers from a prior OOB focus" do
      # focus=500x500 (clamped) is discarded by the region crop; the trailing
      # carried crop reads the reset centre of the region = cell (1,1).
      assert plan_cell([
               {"focus", "500x500"},
               {"crop", "100x100@100x100"},
               {"crop", "12x12"}
             ]) == {1, 1}
    end
  end

  describe "nil-focus carried crop equals a centred crop under pending orientation" do
    # A nil carried point makes a :deferred crop fall back to the centre anchor, so it
    # MUST be pixel-identical to an explicit :center crop under any pending EXIF
    # orientation. This is the invariant `compensate_crop(:deferred)` preserves via
    # center_bias (Orientation.center_discard_sides) — dropping it shifts the kept
    # pixel by one on an odd-extent axis the flush reverses (regressed when the
    # TwicPics default guide moved from :center to :deferred; caught in PR review).

    # A fine, per-pixel-distinct pattern so a 1px discard difference is visible
    # (the 100px-cell grid above would hide it).
    defp fine_pattern(w, h) do
      for x <- 0..(w - 1), y <- 0..(h - 1), reduce: Image.new!(w, h, color: [0, 0, 0]) do
        acc -> Image.Draw.rect!(acc, x, y, 1, 1, color: [rem(x * 6, 256), rem(y * 3, 256), 200])
      end
    end

    defp guided_crop_image(image, orient, guide, {w, h}) do
      plan = %Plan{
        source: %Source.Path{segments: ["x.png"]},
        pipelines: [
          %Pipeline{operations: [%CropGuided{width: {:px, w}, height: {:px, h}, guide: guide}]}
        ],
        output: nil,
        auto_rotate: true,
        resolver: ImagePipe.Parser.TwicPics.Resolver
      }

      {:ok, state} =
        Executor.execute(plan, %State{image: Image.set_orientation!(image, orient)},
          seed_orientation: true
        )

      state.image
    end

    defp assert_images_equal(left, right, context) do
      w = Image.width(left)
      h = Image.height(left)

      assert {w, h} == {Image.width(right), Image.height(right)},
             "#{context}: dimensions diverged"

      # Read each frame to a raw row-major band buffer ONCE rather than crossing
      # the libvips FFI boundary per pixel: across the 4×4 orientation×size matrix
      # the old Image.get_pixel!/3 loop was ~20k operation_call/4 invocations,
      # which tipped this async test past the 60s timeout under CI contention.
      {:ok, lb} = VipsImage.write_to_binary(left)
      {:ok, rb} = VipsImage.write_to_binary(right)

      assert byte_size(lb) == byte_size(rb),
             "#{context}: band layout mismatch #{byte_size(lb)} != #{byte_size(rb)}"

      if lb != rb,
        do: flunk("#{context}: pixel mismatch at #{inspect(first_pixel_mismatch(lb, rb, w, h))}")
    end

    defp first_pixel_mismatch(lb, rb, w, h) do
      bands = div(byte_size(lb), w * h)

      Enum.find(for(y <- 0..(h - 1), x <- 0..(w - 1), do: {x, y}), fn {x, y} ->
        offset = (y * w + x) * bands
        :binary.part(lb, offset, bands) != :binary.part(rb, offset, bands)
      end)
    end

    test "carried (nil focus) == center across axis-reversing orientations and odd extents" do
      image = fine_pattern(41, 81)

      # orientations 2/4/6/7 reverse an axis (or quarter-turn) where center_bias
      # bites; odd-extent crops give the centre an extra pixel to discard.
      for orient <- [2, 4, 6, 7], size <- [{20, 30}, {21, 31}, {20, 31}, {21, 30}] do
        carried = guided_crop_image(image, orient, :deferred, size)
        centered = guided_crop_image(image, orient, :center, size)
        assert_images_equal(carried, centered, "orient=#{orient} crop=#{inspect(size)}")
      end
    end
  end
end

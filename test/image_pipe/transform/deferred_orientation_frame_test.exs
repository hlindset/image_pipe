defmodule ImagePipe.Transform.DeferredOrientationFrameTest do
  use ExUnit.Case, async: true

  # Frame-of-reference parity at the deferred-orientation seams (#182).
  #
  # imgproxy's mainPipeline (processing/processing.go) fixes WHICH frame each op
  # decides in relative to `rotateAndFlip` (stage 7):
  #
  #   trim (stage 2)      → STORAGE frame (before orientation)
  #   scale/rt:auto (6)   → DISPLAY frame (ExtractGeometry swaps src dims first)
  #   applyFilters/pix (9) → DISPLAY frame (after orientation)
  #   padding (12)        → DISPLAY frame (after orientation)
  #
  # ImagePipe defers orientation to a late flush, so each op must reproduce
  # imgproxy's frame choice. These tests pin that without a live imgproxy by using
  # two imgproxy-free oracles:
  #
  #   * DISPLAY-frame ops: imgproxy yields the same pixels for an EXIF-tagged
  #     source and its baked (already-rotated, orientation-1) twin, because it
  #     orients before the op. So `run(storage) == run(display_twin)` is the
  #     parity assertion — the baked twin IS the imgproxy reference.
  #   * trim (STORAGE frame): imgproxy trims the un-rotated pixels, so the twin
  #     trick does NOT hold (imgproxy(storage) != imgproxy(display) when the trim
  #     box is frame-sensitive). The reference is built directly: run the Trim
  #     unit on the storage pixels, then apply the EXIF rotation.

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.{Materializer, PlanExecutor, State}
  alias ImagePipe.Transform.Operation.Trim
  alias Vix.Vips.Image, as: VipsImage

  # ── Source builders ──────────────────────────────────────────────────────────

  # A storage-frame image with distinct, non-symmetric content so a wrong frame
  # decision shows up in pixels. Four colored corner blocks; quarter-turns and
  # flips permute the corners observably. `set_orientation!` writes the libvips
  # `orientation` header directly (what PlanExecutor reads) — NO encoder round
  # trip, so pixels stay exact and smart-bg detection is deterministic (a JPEG
  # round trip tints corners and breaks both). `copy_memory` gives random access.
  defp oriented(image, orientation) do
    {:ok, image} = VipsImage.copy_memory(image)
    Image.set_orientation!(image, orientation)
  end

  defp marked_storage(w, h, orientation) do
    Image.new!(w, h, color: :white)
    |> Image.Draw.rect!(0, 0, div(w, 2), div(h, 2), color: :red)
    |> Image.Draw.rect!(div(w, 2), 0, w - div(w, 2), div(h, 2), color: :green)
    |> Image.Draw.rect!(0, div(h, 2), div(w, 2), h - div(h, 2), color: :blue)
    |> Image.Draw.rect!(div(w, 2), div(h, 2), w - div(w, 2), h - div(h, 2), color: :yellow)
    |> oriented(orientation)
  end

  # The baked DISPLAY-frame twin of a storage source: apply the EXIF orientation
  # for real, then re-tag orientation 1 so a subsequent auto-rotate run is a
  # no-op. autorotate runs over the same in-memory pixels, so storage and twin
  # share an identical pixel basis.
  defp display_twin(storage) do
    {:ok, {baked, _flags}} = Image.autorotate(storage)
    {:ok, baked} = VipsImage.copy_memory(baked)
    Image.set_orientation!(baked, 1)
  end

  # ── Pipeline runners ─────────────────────────────────────────────────────────

  defp run(ops, image, auto_rotate? \\ true) do
    plan = %Plan{
      source: nil,
      output: nil,
      auto_rotate: auto_rotate?,
      pipelines: [%Plan.Pipeline{operations: ops}]
    }

    {:ok, %State{} = s} =
      PlanExecutor.execute(plan, %State{image: image}, seed_orientation: true)

    {:ok, %State{} = s} = Materializer.materialize(s)
    s.image
  end

  # ── Pixel comparison ─────────────────────────────────────────────────────────

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(3 * last, 4), last])
  end

  defp assert_pixels_match(a, b, ctx) do
    assert {Image.width(a), Image.height(a)} == {Image.width(b), Image.height(b)},
           "#{ctx}: dimension mismatch #{inspect({Image.width(a), Image.height(a)})} vs " <>
             inspect({Image.width(b), Image.height(b)})

    for x <- sample_positions(Image.width(a)), y <- sample_positions(Image.height(a)) do
      assert Image.get_pixel!(a, x, y) == Image.get_pixel!(b, x, y),
             "#{ctx}: pixel mismatch at (#{x},#{y})"
    end
  end

  # Display-frame, NON-resampling ops (padding/pixelate): storage run must match
  # the baked twin run (the imgproxy reference) pixel-for-pixel, every EXIF
  # orientation.
  defp assert_display_frame_parity(ops, label) do
    for orientation <- 1..8 do
      storage = marked_storage(40, 80, orientation)
      twin = display_twin(storage)

      out_storage = run(ops, storage)
      out_twin = run(ops, twin)

      assert_pixels_match(out_storage, out_twin, "#{label} EXIF #{orientation}")
    end
  end

  # Resampling ops (rt:auto): a resize's hard-edge resampling does NOT commute
  # with the deferred flip/rotate at the pixel level (a sharp color boundary
  # lands at a sub-pixel-different spot), so pixel parity is the wrong oracle.
  # The #182 bug is a BRANCH flip (fit↔fill) under quarter turns, which — for a
  # non-aspect-matched target — changes the OUTPUT DIMENSIONS. The baked twin is
  # orientation-1, so its branch is computed on display dims (imgproxy's choice);
  # equal output dims ⇔ storage picked imgproxy's branch. Dimensions are
  # resample-noise-free.
  defp assert_branch_parity(ops, label) do
    for orientation <- 1..8 do
      storage = marked_storage(40, 80, orientation)
      twin = display_twin(storage)

      out_storage = run(ops, storage)
      out_twin = run(ops, twin)

      assert {Image.width(out_storage), Image.height(out_storage)} ==
               {Image.width(out_twin), Image.height(out_twin)},
             "#{label} EXIF #{orientation}: branch/dimension mismatch " <>
               "#{inspect({Image.width(out_storage), Image.height(out_storage)})} vs " <>
               inspect({Image.width(out_twin), Image.height(out_twin)})
    end
  end

  # ── 1. rt:auto fill-vs-fit decided in the storage frame ──────────────────────

  test "rt:auto + landscape target classifies in the display frame (matches baked twin)" do
    # 40×80 storage displays 80×40 (landscape) under quarter-turn EXIF 5–8. A
    # landscape target with a DIFFERENT aspect (90×40 = 2.25:1 vs display 2:1)
    # makes the storage-frame classifier pick fit where the display-frame
    # classifier (imgproxy) picks fill — fit and fill then differ in pixels.
    # (An aspect-MATCHED target would collapse fit and fill and hide the bug.)
    {:ok, resize} = Operation.resize(:auto, {:px, 90}, {:px, 40}, enlargement: :allow)
    assert_branch_parity([resize], "rt:auto landscape target")
  end

  test "rt:auto + portrait target classifies in the display frame (matches baked twin)" do
    {:ok, resize} = Operation.resize(:auto, {:px, 50}, {:px, 100}, enlargement: :allow)
    assert_branch_parity([resize], "rt:auto portrait target")
  end

  # ── 1b. Effective-DPR padding-scale cap (resize present) ─────────────────────

  test "no-enlarge effective-DPR padding cap uses the display-frame source dims" do
    # The no-enlarge padding-scale cap (`max_padding_scale_without_enlarge`) sizes
    # the requested box against the source. Under a pending quarter turn it must
    # use the DISPLAY-frame source dims, else the effective-DPR padding width is
    # computed on transposed axes (#182). Geometry chosen so the storage-frame cap
    # (0.8 → scale 1.0) and display-frame cap (1.333 → scale 1.333) diverge, making
    # the padding border — and thus the OUTPUT DIMENSIONS — frame-sensitive.
    {:ok, resize} = Operation.resize(:fit, {:px, 50}, {:px, 30}, dpr: 2)

    {:ok, padding} =
      Operation.padding({:px, 10}, {:px, 10}, {:px, 10}, {:px, 10},
        pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
      )

    assert_branch_parity([resize, padding], "effective-DPR padding cap")
  end

  # ── 2a. Asymmetric padding without resize ────────────────────────────────────

  test "asymmetric padding without resize lands on display sides (matches baked twin)" do
    # Distinct per-side padding so the side it lands on is observable. No resize,
    # so the resize-triggered flush never fires — the padding op itself must
    # decide in the display frame.
    {:ok, padding} =
      Operation.padding({:px, 10}, {:px, 4}, {:px, 2}, {:px, 8}, fill: solid_red())

    assert_display_frame_parity([padding], "asymmetric padding no-resize")
  end

  # ── 2b. Pixelate ─────────────────────────────────────────────────────────────

  test "pixelate block grid aligns in the display frame (matches baked twin)" do
    # Block size 7 does not divide 40 or 80, so partial edge blocks land on a
    # specific display edge. A wrong (pre-flush) frame puts them on the rotated
    # edge.
    {:ok, pix} = Operation.pixelate(7)
    assert_display_frame_parity([pix], "pixelate non-multiple grid")
  end

  # ── 2c. Gradient (directional, display frame) ────────────────────────────────

  test "gradient ramp runs along the display axes (matches baked twin)" do
    # A full-strength down (0°) black gradient is directional: a pre-flush (storage-
    # frame) run would ramp along the storage axes, so under a quarter turn the dark
    # end lands on a rotated edge. Parity with the baked display twin pins it to the
    # display frame.
    {:ok, gradient} =
      Operation.gradient(opacity_full(), black(), 0.0, 0.0, 1.0)

    assert_display_frame_parity([gradient], "down gradient direction")
  end

  test "down gradient's dark end lands on the DISPLAY bottom under a quarter turn" do
    # EXIF 6 is a quarter turn: a 40×80 storage displays as 80×40. A down (0°)
    # gradient must darken toward the DISPLAY bottom. Without the flush-before-
    # gradient clause the ramp runs in the storage frame and the dark end lands on a
    # display SIDE, not the bottom — this assertion then fails.
    {:ok, gradient} = Operation.gradient(opacity_full(), black(), 0.0, 0.0, 1.0)

    out = run([gradient], marked_storage(40, 80, 6))

    {w, h} = {Image.width(out), Image.height(out)}
    mid_x = div(w, 2)
    top_lum = display_lum(out, mid_x, 0)
    bottom_lum = display_lum(out, mid_x, h - 1)

    assert bottom_lum < top_lum - 80,
           "expected display bottom darker than top, got top=#{top_lum} bottom=#{bottom_lum}"
  end

  defp display_lum(image, x, y) do
    image |> Image.get_pixel!(x, y) |> List.flatten() |> hd()
  end

  defp black do
    {:ok, color} = Operation.color(0, 0, 0)
    color
  end

  defp opacity_full, do: {:ratio, 1, 1}

  # ── 3. Trim runs on the storage frame ────────────────────────────────────────

  # Smart-trim storage source: a white frame with a distinct BLACK top-left
  # corner. Smart background = top-left pixel `getpoint(0,0)`, so the storage
  # frame detects black (trims almost nothing) while a rotated display frame
  # detects white at its top-left (trims the white border to the content) —
  # grossly different boxes. Plain uniform-border trim *commutes* with rotation;
  # this corner asymmetry is what makes it frame-sensitive.
  defp trim_smart_storage(orientation) do
    Image.new!(40, 80, color: :white)
    |> Image.Draw.rect!(10, 20, 16, 40, color: :red)
    |> Image.Draw.rect!(0, 0, 8, 8, color: :black)
    |> oriented(orientation)
  end

  # equal_hor storage source: a uniform white border (consistent smart bg) with
  # STRONGLY asymmetric horizontal vs vertical margins. With `equal_hor: true`
  # and `equal_ver: false`, only the horizontal axis is symmetrized — and the
  # storage-horizontal axis is the display-VERTICAL axis under a quarter turn, so
  # the symmetrized box lands on a different physical axis than imgproxy's. (With
  # BOTH equal flags set, a transpose commutes and hides the bug — so this fixes
  # only equal_hor.)
  defp trim_equal_storage(orientation) do
    # content (4, 10, 10, 8): margins left=4 right=26, top=10 bottom=62
    Image.new!(40, 80, color: :white)
    |> Image.Draw.rect!(4, 10, 10, 8, color: :red)
    |> oriented(orientation)
  end

  # Reference: run the Trim unit on the un-rotated storage pixels, then apply the
  # EXIF rotation via autorotate — imgproxy's "trim at stage 2, rotate at stage 7".
  defp trim_storage_then_orient(storage, trim_op, orientation) do
    raw = Image.set_orientation!(storage, 1)
    {:ok, %State{image: trimmed}} = Trim.execute(trim_op, %State{image: raw, materialized?: true})

    {:ok, {oriented, _}} =
      trimmed
      |> Image.set_orientation!(orientation)
      |> Image.autorotate()

    oriented
  end

  defp trim_op(opts) do
    {:ok, %Operation.Trim{} = plan_trim} = Operation.trim(opts)

    %Trim{
      threshold: plan_trim.threshold,
      background: plan_trim.background,
      equal_hor: plan_trim.equal_hor,
      equal_ver: plan_trim.equal_ver
    }
  end

  test "smart trim samples the storage top-left corner (matches storage-frame reference)" do
    {:ok, plan_trim} = Operation.trim(threshold: 10)
    unit = trim_op(threshold: 10)

    for orientation <- 1..8 do
      storage = trim_smart_storage(orientation)
      out = run([plan_trim], storage)
      ref = trim_storage_then_orient(storage, unit, orientation)
      assert_pixels_match(out, ref, "smart trim EXIF #{orientation}")
    end
  end

  test "equal_hor symmetrizes the storage horizontal axis (matches storage-frame reference)" do
    {:ok, plan_trim} = Operation.trim(threshold: 10, equal_hor: true, equal_ver: false)
    unit = trim_op(threshold: 10, equal_hor: true, equal_ver: false)

    for orientation <- 1..8 do
      storage = trim_equal_storage(orientation)
      out = run([plan_trim], storage)
      ref = trim_storage_then_orient(storage, unit, orientation)
      assert_pixels_match(out, ref, "equal_hor trim EXIF #{orientation}")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp solid_red do
    {:ok, color} = Operation.color(255, 0, 0)
    {:solid, color}
  end
end

defmodule ImagePipe.Transform.RotateRoutingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  defp run(ops) do
    {:ok, image} = Image.new(40, 20, color: [10, 20, 30])
    run_on(image, ops)
  end

  defp run_on(image, ops, opts \\ []) do
    auto_rotate = Keyword.get(opts, :auto_rotate, false)

    plan = %Plan{
      source: nil,
      auto_rotate: auto_rotate,
      pipelines: [%Pipeline{operations: ops}],
      output: nil,
      response: %Response{}
    }

    execute_opts = Keyword.take(opts, [:seed_orientation])

    {:ok, %State{image: result}} =
      Transform.execute_plan(plan, %State{image: image}, execute_opts)

    result
  end

  defp red_blue_40x20 do
    {:ok, left} = Image.new(20, 20, color: [255, 0, 0])
    {:ok, right} = Image.new(20, 20, color: [0, 0, 255])
    {:ok, joined} = Operation.join(left, right, :VIPS_DIRECTION_HORIZONTAL)
    joined
  end

  test "arbitrary angle routes to the chain op (bounding box grows, alpha added)" do
    result = run([%PlanRotate{angle: 45, mirror: false}])
    assert Image.width(result) > 40 and Image.height(result) > 20
    assert Image.has_alpha?(result)
  end

  test "right-angle non-mirrored rotation produces a lossless quarter turn" do
    result = run([%PlanRotate{angle: 90, mirror: false}])
    assert Image.width(result) == 20 and Image.height(result) == 40
    refute Image.has_alpha?(result)
  end

  test "right-angle mirrored rotation applies the mirror (differs from non-mirrored)" do
    img = red_blue_40x20()
    mirrored = run_on(img, [%PlanRotate{angle: 90, mirror: true}])
    plain = run_on(img, [%PlanRotate{angle: 90, mirror: false}])

    assert Image.width(mirrored) == 20 and Image.height(mirrored) == 40
    # Same geometry, but the horizontal flip before the turn changes pixel placement:
    # at least one sampled pixel must differ, proving the mirror was applied (not dropped).
    assert Image.get_pixel!(mirrored, 10, 5) != Image.get_pixel!(plain, 10, 5),
           "mirror not applied: mirrored and non-mirrored quarter turns are identical"
  end

  # ── EXIF flush-before-arbitrary-rotate ordering gate ─────────────────────────

  # EXIF orientation 6 stores a portrait image (40×80) that displays as landscape
  # (80×40) — a genuine quarter turn (storage W ≠ display W), so wrong ordering
  # produces a different frame and this test would FAIL.
  #
  # Path A: auto_rotate:true + seed_orientation:true on the oriented source — the
  # real execution path. The arbitrary 30° rotate triggers materialization, which
  # calls OrientationFlush.flush/1 (EXIF first, then copy_memory) before the affine
  # rotate runs. So the rotate sees the 80×40 display frame.
  #
  # Path B: reference — Image.autorotate/1 the source explicitly to get the 80×40
  # display image, then run the same 30° rotate with auto_rotate:false (no pending
  # EXIF, no seed). The rotate sees the same 80×40 display frame.
  #
  # If execution were flush-AFTER-rotate (wrong order), Path A would rotate a 40×80
  # portrait and then flip to landscape — the bounding box would differ from Path B
  # (which rotates an 80×40 landscape), so the dimension assertion would fail.
  test "EXIF orientation is flushed BEFORE arbitrary rotate (display frame ordering)" do
    source = exif6_source()

    # Path A: full auto_rotate execution (flush-then-rotate).
    result_a =
      run_on(source, [%PlanRotate{angle: 30, mirror: false}],
        auto_rotate: true,
        seed_orientation: true
      )

    # Path B: reference — autorotate explicitly, then rotate with no pending EXIF.
    {:ok, {display_frame, _}} = Image.autorotate(source)
    result_b = run_on(display_frame, [%PlanRotate{angle: 30, mirror: false}])

    # Both paths rotate an 80×40 landscape by 30° → identical bounding box.
    # Under wrong ordering (rotate portrait 40×80, then flip), the bounding box
    # of a 30° rotation of a 40×80 frame differs from rotating an 80×40 frame.
    assert {Image.width(result_a), Image.height(result_a)} ==
             {Image.width(result_b), Image.height(result_b)},
           "EXIF flush did not precede the arbitrary rotate (display frame differs from reference)"
  end

  # EXIF-6 source: stored portrait (40 wide × 80 tall), displays as landscape
  # (80 wide × 40 tall) after a 90° CW turn. Written to memory as JPEG so the
  # open has a real EXIF orientation tag (same pattern as deferred_orientation_test).
  defp exif6_source do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(0, 0, 40, 4, color: :red)
    |> Image.set_orientation!(6)
    |> Image.write!(:memory, suffix: ".jpg")
    |> Image.open!(access: :random, fail_on: :error)
  end
end

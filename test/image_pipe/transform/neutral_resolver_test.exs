defmodule ImagePipe.Transform.NeutralResolverTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Bitonal
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Colorize
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gradient
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.Sharpen
  alias ImagePipe.Plan.Operation.Trim
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize, as: ExecResize
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape

  setup do
    shape =
      SourceShape.seed(%{width: 100, height: 80, pending_orientation: nil, decode_shrink: nil})

    %{shape: shape}
  end

  defp padding_op do
    %Padding{
      top: {:px, 2},
      right: {:px, 2},
      bottom: {:px, 2},
      left: {:px, 2},
      pixel_ratio: {:ratio, 1, 1},
      fill: :transparent
    }
  end

  test "trim → :measure, pending kept, storage frame, no Flush", %{shape: s} do
    {ops, {:measure, :trim, nil}} =
      NeutralResolver.resolve(s, nil, %Trim{
        threshold: 10,
        background: :auto,
        equal_hor: false,
        equal_ver: false
      })

    assert [%ImagePipe.Transform.Operation.Trim{}] = ops
    {shape2, nil} = NeutralResolver.continue(:trim, {90, 70}, s, nil)
    assert shape2.frame == :storage and shape2.width == 90
  end

  test "trim under a non-identity pending keeps the pending on the shape" do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})

    {ops, {:measure, :trim, nil}} =
      NeutralResolver.resolve(s, nil, %Trim{
        threshold: 10,
        background: :auto,
        equal_hor: false,
        equal_ver: false
      })

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    {shape2, nil} = NeutralResolver.continue(:trim, {90, 70}, s, nil)
    assert shape2.frame == :storage
    assert shape2.pending_orientation == po
    assert shape2.decode_shrink == nil
  end

  test "effect (blur) → :advance, dims unchanged, no Flush", %{shape: s} do
    {ops, {:advance, %SourceShape{width: 100, height: 80}, nil}} =
      NeutralResolver.resolve(s, nil, %Blur{sigma: 1.0})

    assert [%ImagePipe.Transform.Operation.Blur{}] = ops
  end

  test "identity pending: no Flush emitted, pending cleared on the shape" do
    identity = PendingOrientation.from_exif(1, true)

    s =
      SourceShape.seed(%{
        width: 100,
        height: 80,
        pending_orientation: identity,
        decode_shrink: nil
      })

    {ops, {:advance, shape2, nil}} = NeutralResolver.resolve(s, nil, padding_op())

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    assert shape2.pending_orientation == nil
    assert {shape2.width, shape2.height} == {104, 84}
  end

  test "padding under a non-identity pending flushes first, display-frame dims" do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})

    {ops, {:advance, shape2, nil}} = NeutralResolver.resolve(s, nil, padding_op())

    assert [%Flush{}, %ImagePipe.Transform.Operation.Padding{}] = ops
    assert shape2.pending_orientation == nil
    assert shape2.frame == :display
    # quarter turn: 100x80 storage displays as 80x100, plus 2px on each side
    assert {shape2.width, shape2.height} == {84, 104}
  end

  test "right-angle rotate folds into the pending with zero ops", %{shape: s} do
    {[], {:advance, shape2, nil}} =
      NeutralResolver.resolve(s, nil, %PlanRotate{angle: 90, mirror: false})

    assert %PendingOrientation{user_angle: 90} = shape2.pending_orientation
    assert {shape2.width, shape2.height} == {100, 80}
  end

  test "resize under a non-identity pending stages the flush and advances at the seam" do
    po = PendingOrientation.from_exif(3, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})

    resize = %PlanResize{
      mode: :fit,
      width: {:px, 50},
      height: {:px, 40},
      dpr: {:ratio, 1, 1},
      enlargement: :forbid,
      guide: :center
    }

    # Staged: the resize is the terminal op of the first stage; the flush (and
    # any result-crop tail) arrives via the stage continue/4 returns, and the
    # shape only advances at that stage's :advance continuation.
    {[%ExecResize{}], {:measure, {:resize_flush_tail, _} = tag, nil}} =
      NeutralResolver.resolve(s, nil, resize)

    {stage_ops, {:advance, shape2, nil}} = NeutralResolver.continue(tag, {50, 40}, s, nil)
    assert %Flush{} = List.last(stage_ops)
    refute Enum.any?(stage_ops, &match?(%ExecResize{}, &1))
    assert shape2.frame == :display
    assert shape2.pending_orientation == nil
    assert shape2.decode_shrink == nil
    assert {shape2.width, shape2.height} == {50, 40}
  end

  test "resize with no pending emits no Flush and keeps the frame", %{shape: s} do
    resize = %PlanResize{
      mode: :fit,
      width: {:px, 50},
      height: {:px, 40},
      dpr: {:ratio, 1, 1},
      enlargement: :forbid,
      guide: :center
    }

    {ops, {:measure, :resize, nil}} = NeutralResolver.resolve(s, nil, resize)

    refute Enum.any?(ops, &match?(%Flush{}, &1))
    {shape2, nil} = NeutralResolver.continue(:resize, {50, 40}, s, nil)
    assert shape2.frame == :storage
    assert shape2.decode_shrink == nil
  end

  test "arbitrary rotate → :measure; continue lands the display frame", %{shape: s} do
    {ops, {:measure, :rotate, nil}} =
      NeutralResolver.resolve(s, nil, %PlanRotate{angle: 45, mirror: false})

    refute ops == []
    {shape2, nil} = NeutralResolver.continue(:rotate, {128, 128}, s, nil)
    assert shape2.frame == :display
    assert shape2.pending_orientation == nil
    assert {shape2.width, shape2.height} == {128, 128}
    assert shape2.decode_shrink == s.decode_shrink
  end

  test "region crop under a non-identity pending flushes before the crop" do
    po = PendingOrientation.from_exif(6, true)
    s = SourceShape.seed(%{width: 100, height: 80, pending_orientation: po, decode_shrink: nil})

    crop = %CropRegion{x: {:px, 0}, y: {:px, 0}, width: {:px, 30}, height: {:px, 20}}

    {ops, {:advance, shape2, nil}} = NeutralResolver.resolve(s, nil, crop)

    assert [%Flush{}, %ImagePipe.Transform.Operation.Crop{}] = ops
    assert shape2.pending_orientation == nil
    assert shape2.frame == :display
    assert shape2.decode_shrink == nil
    assert {shape2.width, shape2.height} == {30, 20}
  end

  describe "resolve_late_bound_guide/2" do
    test "a guided crop resolves late to a concrete crop, never a marker" do
      for pending <- [
            nil,
            PendingOrientation.from_exif(3, true),
            PendingOrientation.from_exif(6, true)
          ] do
        shape =
          SourceShape.seed(%{
            width: 101,
            height: 80,
            pending_orientation: pending,
            decode_shrink: nil
          })

        operation = %CropGuided{width: {:px, 31}, height: {:px, 20}, guide: :center}

        assert {[%Crop{} = late_crop], late_continuation} =
                 NeutralResolver.resolve_late_bound_guide(shape, operation)

        # A concrete crop is emitted; no deferred marker gravity survives.
        refute late_crop.gravity == :deferred

        if pending do
          # The orientation compensation is folded into the crop's center bias.
          assert late_crop.center_bias == Orientation.center_discard_sides(pending)
        else
          # With no pending orientation the late-bound path is exactly the
          # neutral resolution of the concrete-guide crop.
          assert {[%Crop{} = plain_crop], plain_continuation} =
                   NeutralResolver.resolve(shape, nil, operation)

          assert late_crop == plain_crop
          assert late_continuation == plain_continuation
        end

        # The crop resolves to the requested 31×20 extent for a concrete gravity
        # ({20, 31} when a quarter-turn pending swaps the storage-frame axes).
        for gravity <- [{:anchor, :center, :center}, {:fp, 0.2, 0.8}] do
          assert {:ok, %{left: left, top: top, width: w, height: h}} =
                   Crop.resolved_rect(%Crop{late_crop | gravity: gravity}, 101, 80)

          assert is_integer(left) and is_integer(top)
          assert {w, h} in [{31, 20}, {20, 31}]
        end
      end
    end

    test "a cover resize resolves late through a staged measure with odd-pixel bias" do
      operation = %PlanResize{
        mode: :cover,
        width: {:px, 31},
        height: {:px, 20},
        dpr: {:ratio, 1, 1},
        enlargement: :forbid,
        guide: :center
      }

      for pending <- [
            nil,
            PendingOrientation.from_exif(3, true),
            PendingOrientation.from_exif(6, true)
          ] do
        shape =
          SourceShape.seed(%{
            width: 101,
            height: 80,
            pending_orientation: pending,
            decode_shrink: nil
          })

        # The cover stages: a forcing resize now, its result crop after measure.
        assert {[%ExecResize{}], {:measure, late_tag, nil}} =
                 NeutralResolver.resolve_late_bound_guide(shape, operation)

        assert {late_tail, late_continuation} =
                 NeutralResolver.continue(late_tag, {33, 27}, shape, nil)

        # The tail carries the result crop (and a %Flush{} when a pending
        # orientation must flush after the storage-frame crop).
        assert %Crop{} = tail_crop = Enum.find(late_tail, &match?(%Crop{}, &1))
        refute tail_crop.gravity == :deferred
        assert match?({:advance, %SourceShape{}, nil}, late_continuation)

        if pending do
          assert tail_crop.center_bias == Orientation.center_discard_sides(pending)
        end

        # The result crop resolves to a well-formed rectangle against the
        # measured seam frame for a concrete gravity.
        for gravity <- [{:anchor, :center, :center}, {:fp, 0.2, 0.8}] do
          assert {:ok, %{left: left, top: top, width: w, height: h}} =
                   realized_tail_rect(late_tail, gravity, {33, 27})

          assert is_integer(left) and is_integer(top)
          assert is_integer(w) and is_integer(h)
        end
      end
    end
  end

  defp realized_tail_rect(ops, gravity, {width, height}) do
    case Enum.find(ops, &match?(%Crop{}, &1)) do
      nil -> nil
      %Crop{} = crop -> Crop.resolved_rect(%Crop{crop | gravity: gravity}, width, height)
    end
  end

  # ── :auto fill-vs-fit bucketing (imgproxy ResizeAuto parity, #182/#233) ─────
  # The neutral column owns the source-dependent :auto rule: fill when source
  # and target orientation match (square shares the landscape bucket), fit
  # otherwise, compared on the DISPLAY axes (imgproxy prepare.go:88-97).
  describe ":auto resize mode bucketing" do
    defp auto_resize(width, height) do
      %PlanResize{
        mode: :auto,
        width: width,
        height: height,
        dpr: {:ratio, 1, 1},
        enlargement: :forbid,
        guide: :center
      }
    end

    defp shape_for(w, h, po \\ nil) do
      SourceShape.seed(%{width: w, height: h, pending_orientation: po, decode_shrink: nil})
    end

    test "landscape source × landscape target → cover" do
      assert :cover =
               NeutralResolver.resolve_mode(
                 auto_resize({:px, 300}, {:px, 200}),
                 shape_for(800, 600)
               )
    end

    test "landscape source × portrait target → fit" do
      assert :fit =
               NeutralResolver.resolve_mode(
                 auto_resize({:px, 200}, {:px, 300}),
                 shape_for(800, 600)
               )
    end

    test "square source shares the landscape bucket (→ cover against a landscape target)" do
      assert :cover =
               NeutralResolver.resolve_mode(
                 auto_resize({:px, 300}, {:px, 200}),
                 shape_for(500, 500)
               )
    end

    test "square target shares the landscape bucket (→ cover against a landscape source)" do
      assert :cover =
               NeutralResolver.resolve_mode(
                 auto_resize({:px, 200}, {:px, 200}),
                 shape_for(800, 600)
               )
    end

    test "an auto (omitted) target dimension keeps the conservative fit branch" do
      assert :fit =
               NeutralResolver.resolve_mode(auto_resize(:auto, {:px, 200}), shape_for(800, 600))
    end

    test "concrete modes pass through unchanged" do
      assert :fit =
               NeutralResolver.resolve_mode(
                 %{auto_resize({:px, 1}, {:px, 1}) | mode: :fit},
                 shape_for(800, 600)
               )

      assert :cover =
               NeutralResolver.resolve_mode(
                 %{auto_resize({:px, 1}, {:px, 1}) | mode: :cover},
                 shape_for(800, 600)
               )

      assert :stretch =
               NeutralResolver.resolve_mode(
                 %{auto_resize({:px, 1}, {:px, 1}) | mode: :stretch},
                 shape_for(800, 600)
               )
    end

    # #182: the sign comparison runs on DISPLAY-frame source dims. A pending
    # quarter turn (EXIF 6) displays a portrait-storage source as landscape, so
    # a landscape target buckets to cover — not the fit a storage-axis compare
    # would pick.
    test "classifies against the display-frame source under a pending quarter turn" do
      po = PendingOrientation.from_exif(6, true)
      # storage 600×800 (portrait) displays as 800×600 (landscape) under EXIF 6
      shape = shape_for(600, 800, po)
      assert :cover = NeutralResolver.resolve_mode(auto_resize({:px, 300}, {:px, 200}), shape)
    end

    test "resolve/3 buckets :auto end-to-end and lowers to a concrete executable resize" do
      {[%ExecResize{mode: :fill}], {:measure, _tag, nil}} =
        NeutralResolver.resolve(shape_for(800, 600), nil, auto_resize({:px, 300}, {:px, 200}))
    end
  end

  # ── §4.7 narrowing gate ────────────────────────────────────────────────────
  # Enumerates every ImagePipe.Plan.Operation.* variant and asserts the
  # continuation tag NeutralResolver.resolve/3 returns for a representative,
  # minimally-valid instance. This is the driver's core :measure/:advance
  # contract (spec §4.7): :measure iff the op is %Resize{}, %Trim{}, or
  # %Rotate{} with an angle outside [0, 90, 180, 270] or mirror: true;
  # :advance for everything else. Defining a private classify/1 helper would
  # not prove this — the assertion below drives the real resolve/3 dispatch,
  # so a newly added op with no classification clause fails loudly here
  # instead of silently falling through to the wrong tag.
  @white Color.white()

  describe "§4.7 narrowing: every Plan.Operation.* is classified :measure or :advance" do
    @measure_ops [
      {"Resize",
       %PlanResize{
         mode: :fit,
         width: {:px, 50},
         height: {:px, 40},
         dpr: {:ratio, 1, 1},
         enlargement: :forbid,
         guide: :center
       }},
      {"Resize (mode: :auto)",
       %PlanResize{
         mode: :auto,
         width: {:px, 50},
         height: {:px, 40},
         dpr: {:ratio, 1, 1},
         enlargement: :forbid,
         guide: :center
       }},
      {"Trim", %Trim{threshold: 10, background: :auto, equal_hor: false, equal_ver: false}},
      {"Rotate (arbitrary angle, no mirror)", %PlanRotate{angle: 45, mirror: false}},
      {"Rotate (right-angle, mirrored)", %PlanRotate{angle: 90, mirror: true}}
    ]

    @advance_ops [
      {"Background", %Background{color: @white}},
      {"Bitonal", %Bitonal{}},
      {"Blur", %Blur{sigma: 1.0}},
      {"Brightness", %Brightness{value: 10}},
      {"Canvas",
       %Canvas{
         width: {:px, 120},
         height: {:px, 100},
         placement: :center,
         fill: :transparent,
         overflow: :reject
       }},
      {"Colorize", %Colorize{opacity: {:ratio, 1, 1}, color: @white, keep_alpha: false}},
      {"Contrast", %Contrast{value: 10}},
      {"CropGuided", %CropGuided{width: {:px, 30}, height: {:px, 20}, guide: :center}},
      {"CropRegion", %CropRegion{x: {:px, 0}, y: {:px, 0}, width: {:px, 30}, height: {:px, 20}}},
      {"Duotone", %Duotone{intensity: {:ratio, 1, 1}, shadow: @white, highlight: @white}},
      {"Flip", %Flip{axis: :horizontal}},
      {"Gradient",
       %Gradient{opacity: {:ratio, 1, 1}, color: @white, angle: 0.0, start: 0.0, stop: 1.0}},
      {"Gray", %Gray{}},
      {"Monochrome", %Monochrome{intensity: {:ratio, 1, 1}, color: @white}},
      {"Padding",
       %Padding{
         top: {:px, 2},
         right: {:px, 2},
         bottom: {:px, 2},
         left: {:px, 2},
         pixel_ratio: {:ratio, 1, 1},
         fill: :transparent
       }},
      {"Pixelate", %Pixelate{size: 8}},
      {"Rotate (right-angle, no mirror)", %PlanRotate{angle: 90, mirror: false}},
      {"Saturation", %Saturation{value: 10}},
      {"Sharpen", %Sharpen{sigma: 1.0}}
    ]

    test "measure-classified ops", %{shape: s} do
      for {label, op} <- @measure_ops do
        {_ops, continuation} = NeutralResolver.resolve(s, nil, op)

        assert match?({:measure, _tag, nil}, continuation),
               "expected #{label} (#{inspect(op)}) to resolve :measure, got #{inspect(continuation)}"
      end
    end

    test "advance-classified ops", %{shape: s} do
      for {label, op} <- @advance_ops do
        {_ops, continuation} = NeutralResolver.resolve(s, nil, op)

        assert match?({:advance, %SourceShape{}, nil}, continuation),
               "expected #{label} (#{inspect(op)}) to resolve :advance, got #{inspect(continuation)}"
      end
    end

    # Stage invariant (spec §4.4 Stage 3): a %Transform.Operation.Resize{} is
    # always the TERMINAL op of its stage — the emitted list ends at the
    # resize, and any tail arrives via the stage continue/4 returns, already
    # resize-free. PointFlow's seam scaling relies on this.
    test "a resize is the terminal op of its stage", %{shape: s} do
      op = %PlanResize{
        mode: :cover,
        width: {:px, 50},
        height: {:px, 40},
        dpr: {:ratio, 1, 1},
        enlargement: :forbid,
        guide: :center
      }

      {ops, {:measure, tag, nil}} = NeutralResolver.resolve(s, nil, op)
      assert [%ExecResize{}] = ops

      case NeutralResolver.continue(tag, {50, 40}, s, nil) do
        {%SourceShape{}, nil} ->
          :ok

        {stage_ops, _continuation} when is_list(stage_ops) ->
          refute Enum.any?(stage_ops, &match?(%ExecResize{}, &1))
      end
    end
  end
end

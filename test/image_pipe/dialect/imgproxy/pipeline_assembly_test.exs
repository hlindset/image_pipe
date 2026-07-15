defmodule ImagePipe.Dialect.Imgproxy.PipelineAssemblyTest do
  use ExUnit.Case, async: true

  # THE CROSS-ARM GUARD.
  #
  # `Assembly.operations/1` is a phase-1 copy of the frozen framework arm's
  # `PlanBuilder.plan_geometry/1`. Both arms run side by side and the imgproxy
  # differential suite compares their output, so any drift between them is a
  # silent conformance regression — and R4's review proved that hand-written
  # dialect tests do NOT catch it: they pinned four divergences green, because
  # every expected value was read off the dialect's own output.
  #
  # So this file does not assert expectations of its own. It feeds the SAME
  # request fields to BOTH arms and asserts they agree: the framework's
  # `PlanBuilder.to_plan/2` is the oracle. A stage that drifts fails here, and
  # an expectation cannot be "corrected" to match a bug without editing the
  # frozen arm.
  #
  # The one deliberate divergence [spec D5] is asserted rather than normalized
  # away: the framework emits a padding `pixel_ratio` of `{:effective, fallback,
  # mode}` (a marker its resolver resolves at run time); the dialect owns both
  # emit and run, so it emits the concrete `fallback` and carries `mode` in
  # `Assembly.pipeline_ctx/1`. `assert_arms_agree/2` checks that correspondence
  # exactly — fallback AND mode — so the marker's information cannot be lost.

  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Pipeline

  @dialect_request ImagePipe.Dialect.Imgproxy.PipelineRequest
  @framework_request ImagePipe.Parser.Imgproxy.PipelineRequest

  # Sub-struct fields differ only by module name between the two arms, so a row
  # supplies them as plain keyword lists and each arm builds its own copy.
  @sub_structs %{
    effects: {ImagePipe.Dialect.Imgproxy.Effects, ImagePipe.Parser.Imgproxy.Effects},
    orientation: {ImagePipe.Dialect.Imgproxy.Orientation, ImagePipe.Parser.Imgproxy.Orientation},
    crop: {ImagePipe.Dialect.Imgproxy.CropRequest, ImagePipe.Parser.Imgproxy.CropRequest}
  }

  defp color!(r, g, b) do
    {:ok, color} = Color.rgb(r, g, b)
    color
  end

  # --- the two arms -------------------------------------------------------

  defp dialect_operations(fields) do
    Assembly.operations(build_request(@dialect_request, fields, 0))
  end

  # The framework arm reached through its real public entry point. `to_plan/2`
  # stamps `smart_crop_face_detection` onto every pipeline from the imgproxy
  # opts, so the row's own value is threaded back in as that opt to keep the
  # round-trip faithful.
  defp framework_operations(fields) do
    preq = build_request(@framework_request, fields, 1)

    parsed = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [preq],
      output: ParsedRequest.output_request()
    }

    opts = [imgproxy: [smart_crop_face_detection: preq.smart_crop_face_detection]]

    case PlanBuilder.to_plan(parsed, opts) do
      {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} -> {:ok, operations}
      {:error, _reason} = error -> error
    end
  end

  defp build_request(module, fields, arm_index) do
    fields
    |> Enum.map(fn {key, value} -> {key, build_field(key, value, arm_index)} end)
    |> then(&struct!(module, &1))
  end

  defp build_field(key, value, arm_index) when is_list(value) do
    case Map.fetch(@sub_structs, key) do
      {:ok, modules} -> struct!(elem(modules, arm_index), value)
      :error -> value
    end
  end

  defp build_field(_key, value, _arm_index), do: value

  # --- the comparison -----------------------------------------------------

  defp assert_arms_agree(fields) do
    case {framework_operations(fields), dialect_operations(fields)} do
      {{:error, framework_reason}, {:error, dialect_reason}} ->
        assert dialect_reason == framework_reason

      {{:ok, framework_ops}, {:ok, dialect_ops}} ->
        assert length(dialect_ops) == length(framework_ops),
               "op count differs\nframework: #{inspect(framework_ops, pretty: true)}\ndialect:   #{inspect(dialect_ops, pretty: true)}"

        Enum.zip(framework_ops, dialect_ops)
        |> Enum.each(&assert_op_agrees(&1, fields))

        {:ok, dialect_ops}

      {framework, dialect} ->
        flunk("""
        one arm errored and the other did not
        framework: #{inspect(framework, pretty: true)}
        dialect:   #{inspect(dialect, pretty: true)}
        """)
    end
  end

  # The D5 marker correspondence: the framework's `{:effective, fallback, mode}`
  # must decompose into exactly the dialect's concrete `pixel_ratio` plus the
  # mode `pipeline_ctx/1` carries. Every other field, and every other operation,
  # must match outright.
  defp assert_op_agrees({%Padding{} = framework_op, %Padding{} = dialect_op}, fields) do
    mode = Assembly.pipeline_ctx(build_request(@dialect_request, fields, 0)).mode

    assert framework_op.pixel_ratio == {:effective, dialect_op.pixel_ratio, mode},
           "padding marker correspondence broken: framework #{inspect(framework_op.pixel_ratio)} " <>
             "vs dialect #{inspect(dialect_op.pixel_ratio)} + mode #{inspect(mode)}"

    assert %Padding{dialect_op | pixel_ratio: nil} == %Padding{framework_op | pixel_ratio: nil}
  end

  defp assert_op_agrees({framework_op, dialect_op}, _fields) do
    assert dialect_op == framework_op
  end

  # --- rows ---------------------------------------------------------------
  #
  # A capped-geometry base shared by the mode/carry rows: 800x600 requested with
  # enlargement denied, the shape whose padding scale the framework's resolver
  # and the dialect's carry math both have to agree on.
  @capped [width: {:pixels, 800}, height: {:pixels, 600}, resizing_type: :force, enlarge: false]

  describe "stage 1: trim" do
    test "trim options pass through unchanged" do
      assert_arms_agree(
        trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false]
      )
    end

    test "an explicit trim background and equal flags" do
      assert_arms_agree(
        trim: [threshold: 5.0, background: color!(255, 0, 0), equal_hor: true, equal_ver: true]
      )
    end
  end

  describe "stage 2: orientation" do
    test "a rotate alone" do
      for angle <- [90, 180, 270] do
        assert_arms_agree(orientation: [rotate: angle])
      end
    end

    test "rotate 0 emits nothing" do
      assert {:ok, []} = assert_arms_agree(orientation: [rotate: 0])
    end

    test "a flip alone, on each axis" do
      for axis <- [:horizontal, :vertical, :both] do
        assert_arms_agree(orientation: [flip: axis])
      end
    end

    test "rotate and flip together, rotate first" do
      assert {:ok, [rotate, flip]} = assert_arms_agree(orientation: [rotate: 90, flip: :vertical])

      assert %Plan.Operation.Rotate{} = rotate
      assert %Plan.Operation.Flip{} = flip
    end

    test "auto_orient is not an operation" do
      assert {:ok, []} = assert_arms_agree(orientation: [auto_orient: true])
    end
  end

  describe "stage 3: crop" do
    test "a bare pixel crop" do
      assert_arms_agree(crop: [width: {:pixels, 100}, height: {:pixels, 100}])
    end

    test "a zero/auto crop dimension means the full axis" do
      assert_arms_agree(crop: [width: {:pixels, 0}, height: {:pixels, 50}])
      assert_arms_agree(crop: [width: :auto, height: :auto])
    end

    test "a scale crop dimension becomes a ratio measure" do
      assert_arms_agree(crop: [width: {:scale, 0.5}, height: {:scale, 0.25}])
    end

    test "a bare crop inherits the top-level gravity AND its offsets" do
      # `crop_gravity/2`'s first clause. Reading only the type, or defaulting the
      # offsets to zero, diverges here.
      assert_arms_agree(
        crop: [width: {:pixels, 100}, height: {:pixels, 100}],
        gravity: {:anchor, :left, :top},
        gravity_x_offset: {:pixels, 12.0},
        gravity_y_offset: {:pixels, 34.0}
      )
    end

    test "an inline crop gravity fully specifies its own gravity and offsets" do
      assert_arms_agree(
        crop: [
          width: {:pixels, 100},
          height: {:pixels, 100},
          gravity: {:anchor, :right, :bottom},
          x_offset: {:pixels, 5.0},
          y_offset: {:pixels, 7.0}
        ],
        gravity: {:anchor, :left, :top},
        gravity_x_offset: {:pixels, 99.0},
        gravity_y_offset: {:pixels, 99.0}
      )
    end

    test "crop gravity types the resize guide also understands" do
      for gravity <- [
            :sm,
            {:fp, 0.25, 0.75},
            {:obj, ["face"]},
            {:obj, []},
            {:obj, ["all"]},
            {:objw, [{"face", 2.0}, {"all", 1.0}]},
            {:objw, [{"dog", 0.5}, {"cat", 0.5}]}
          ] do
        assert_arms_agree(crop: [width: {:pixels, 100}, height: {:pixels, 100}, gravity: gravity])
      end
    end

    test "a crop anchor gravity uses the crop anchor table, not resize_guide's" do
      # `tagged_gravity/2`'s anchor clause routes through `crop_anchor_guide/2`,
      # which maps center/center to :center — but unlike `resize_guide/2` it has
      # no separate center clause. Every anchor must agree.
      for x <- [:left, :center, :right], y <- [:top, :center, :bottom] do
        assert_arms_agree(
          crop: [width: {:pixels, 100}, height: {:pixels, 100}, gravity: {:anchor, x, y}]
        )
      end
    end

    test "smart crop gravity with face assist on" do
      assert_arms_agree(
        crop: [width: {:pixels, 100}, height: {:pixels, 100}, gravity: :sm],
        smart_crop_face_detection: true
      )
    end

    test "crop aspect ratio and its enlarge flag" do
      assert_arms_agree(
        crop: [width: {:pixels, 100}, height: {:pixels, 100}],
        crop_aspect_ratio: 1.5,
        crop_aspect_ratio_enlarge: true
      )
    end

    test "a zero crop aspect ratio is dropped" do
      assert_arms_agree(
        crop: [width: {:pixels, 100}, height: {:pixels, 100}],
        crop_aspect_ratio: 0.0
      )
    end
  end

  describe "stage 4: resize" do
    test "each resizing type with both dimensions" do
      for type <- [:fit, :fill, :fill_down, :force, :auto] do
        assert_arms_agree(
          [resizing_type: type] ++ [width: {:pixels, 300}, height: {:pixels, 200}]
        )
      end
    end

    test "the {:auto, :auto, false} emission guard" do
      # w:0 with no height and no rule: the dimensions must be MAPPED before the
      # guard sees them, or the guard is unreachable and a resize is emitted.
      assert {:ok, []} = assert_arms_agree(width: {:pixels, 0})
      assert {:ok, []} = assert_arms_agree(width: nil, height: nil)
      assert {:ok, []} = assert_arms_agree(width: {:pixels, 0}, height: {:pixels, 0})
    end

    test "the guard's third element: the same geometry WITH a resize rule emits" do
      for rule <- [[dpr: 2.0], [zoom_x: 0.5], [zoom_y: 0.5], [min_width: {:pixels, 100}]] do
        assert {:ok, [%Plan.Operation.Resize{}]} =
                 assert_arms_agree([width: {:pixels, 0}] ++ rule)
      end
    end

    test "the w:0/h:0 clause outranks the resizing_type :auto clause" do
      # Clause ORDER, made observable. `resize_operations/1`'s w:0/h:0 clause sits
      # BEFORE its `resizing_type: :auto` clause, so a ruleless auto/auto request
      # emits nothing. Reordering the two — putting :auto first, as a reader might
      # think the more specific match deserves — routes this straight to
      # `resize_operation/1` and emits a `Resize{mode: :auto}` the framework
      # arm does not.
      assert {:ok, []} =
               assert_arms_agree(
                 resizing_type: :auto,
                 width: {:pixels, 0},
                 height: {:pixels, 0}
               )
    end

    test "resizing_type :auto with one concrete dimension emits" do
      assert {:ok, [%Plan.Operation.Resize{mode: :auto}]} =
               assert_arms_agree(
                 resizing_type: :auto,
                 width: {:pixels, 0},
                 height: {:pixels, 200}
               )
    end

    test "fill_down denies enlargement even with el:1" do
      assert_arms_agree(
        resizing_type: :fill_down,
        width: {:pixels, 800},
        height: {:pixels, 600},
        enlarge: true
      )
    end

    test "enlarge on every other type" do
      for type <- [:fit, :fill, :force, :auto], enlarge <- [true, false] do
        assert_arms_agree(
          resizing_type: type,
          width: {:pixels, 800},
          height: {:pixels, 600},
          enlarge: enlarge
        )
      end
    end

    test "the full opt list the carry math reads back" do
      assert_arms_agree(
        width: {:pixels, 800},
        height: {:pixels, 600},
        min_width: {:pixels, 100},
        min_height: {:pixels, 80},
        zoom_x: 0.5,
        zoom_y: 1.5,
        dpr: 2.0
      )
    end

    test "mw:0/mh:0 mean no minimum on that axis, not unset" do
      assert_arms_agree(
        width: {:pixels, 800},
        min_width: {:pixels, 0},
        min_height: {:pixels, 0}
      )
    end

    test "fill-family types carry the gravity offsets, others do not" do
      for type <- [:fit, :fill, :fill_down, :force, :auto] do
        assert_arms_agree(
          resizing_type: type,
          width: {:pixels, 300},
          height: {:pixels, 200},
          gravity_x_offset: {:pixels, 11.0},
          gravity_y_offset: {:scale, 0.5}
        )
      end
    end

    test "every resize guide gravity" do
      for gravity <- [
            :sm,
            {:fp, 0.25, 0.75},
            {:fp, 0, 1},
            {:obj, ["face"]},
            {:obj, []},
            {:obj, ["all"]},
            {:objw, [{"face", 2.0}, {"all", 1.0}]},
            {:objw, [{"face", 1.0}]},
            {:objw, [{"all", 1.0}]},
            {:objw, [{"face", 2.0}, {"face", 3.0}]},
            {:anchor, :center, :center},
            {:anchor, :left, :top},
            {:anchor, :right, :bottom}
          ] do
        assert_arms_agree(
          resizing_type: :fill,
          width: {:pixels, 300},
          height: {:pixels, 200},
          gravity: gravity
        )
      end
    end

    test "smart resize gravity with face assist on" do
      assert_arms_agree(
        resizing_type: :fill,
        width: {:pixels, 300},
        height: {:pixels, 200},
        gravity: :sm,
        smart_crop_face_detection: true
      )
    end
  end

  describe "plan_geometry's missing_dimensions guards" do
    test "fill without either dimension is rejected" do
      assert_arms_agree(resizing_type: :fill, width: nil, height: nil)
    end

    test "fill without one dimension is rejected" do
      assert_arms_agree(resizing_type: :fill, width: nil, height: {:pixels, 100})
      assert_arms_agree(resizing_type: :fill, width: {:pixels, 100}, height: nil)
    end

    test "fill_down and auto without one dimension are rejected" do
      for type <- [:fill_down, :auto] do
        assert_arms_agree(resizing_type: type, width: nil, height: {:pixels, 100})
        assert_arms_agree(resizing_type: type, width: {:pixels, 100}, height: nil)
        assert_arms_agree(resizing_type: type, width: nil, height: nil)
      end
    end

    test "the guards fire before any other stage, so a trim does not mask them" do
      assert_arms_agree(
        trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
        resizing_type: :fill,
        width: nil,
        height: nil
      )
    end

    test "the rejection reason names the resizing type" do
      assert {:error, {:missing_dimensions, :fill}} =
               dialect_operations(resizing_type: :fill, width: nil, height: nil)

      assert {:error, {:missing_dimensions, :fill_down}} =
               dialect_operations(resizing_type: :fill_down, width: nil, height: nil)

      assert {:error, {:missing_dimensions, :auto}} =
               dialect_operations(resizing_type: :auto, width: nil, height: nil)
    end

    test "a zero-sentinel dimension is NOT a missing dimension" do
      # `{:pixels, 0}` is "auto", not "unset" — the guards key off `nil` only, so
      # this reaches the resize stage and emits, where `width: nil` would reject.
      assert {:ok, [%Plan.Operation.Resize{mode: :cover}]} =
               assert_arms_agree(
                 resizing_type: :fill,
                 width: {:pixels, 0},
                 height: {:pixels, 200}
               )

      assert {:error, {:missing_dimensions, :fill}} =
               dialect_operations(resizing_type: :fill, width: nil, height: {:pixels, 200})
    end
  end

  describe "stage 5: effects" do
    test "blur, sharpen and pixelate" do
      assert_arms_agree(effects: [blur: 2.0, sharpen: 1.5, pixelate: 4])
    end

    test "monochrome with and without an explicit color" do
      assert_arms_agree(effects: [monochrome: [intensity: {:ratio, 1, 2}]])

      assert_arms_agree(
        effects: [monochrome: [intensity: {:ratio, 1, 1}, color: color!(10, 20, 30)]]
      )
    end

    test "duotone with and without explicit colors" do
      assert_arms_agree(effects: [duotone: [intensity: {:ratio, 1, 2}]])

      assert_arms_agree(
        effects: [
          duotone: [
            intensity: {:ratio, 1, 1},
            shadow: color!(1, 2, 3),
            highlight: color!(250, 251, 252)
          ]
        ]
      )
    end

    test "brightness, contrast and saturation" do
      assert_arms_agree(effects: [brightness: 50, contrast: 1.5, saturation: 0.5])
      assert_arms_agree(effects: [brightness: -50])
    end

    test "colorize with and without its options" do
      assert_arms_agree(effects: [colorize: [opacity: {:ratio, 1, 2}]])

      assert_arms_agree(
        effects: [colorize: [opacity: {:ratio, 1, 1}, color: color!(9, 8, 7), keep_alpha: true]]
      )
    end

    test "gradient with and without its options" do
      assert_arms_agree(effects: [gradient: [opacity: {:ratio, 1, 2}]])

      assert_arms_agree(
        effects: [
          gradient: [
            opacity: {:ratio, 1, 1},
            color: color!(4, 5, 6),
            angle: 90.0,
            start: 0.25,
            stop: 0.75
          ]
        ]
      )
    end

    test "every effect at once, in plan_builder's fixed order" do
      assert {:ok, ops} =
               assert_arms_agree(
                 effects: [
                   blur: 2.0,
                   sharpen: 1.5,
                   pixelate: 4,
                   monochrome: [intensity: {:ratio, 1, 2}],
                   duotone: [intensity: {:ratio, 1, 2}],
                   brightness: 10,
                   contrast: 1.5,
                   saturation: 0.5,
                   colorize: [opacity: {:ratio, 1, 2}],
                   gradient: [opacity: {:ratio, 1, 2}]
                 ]
               )

      assert [
               %Plan.Operation.Blur{},
               %Plan.Operation.Sharpen{},
               %Plan.Operation.Pixelate{},
               %Plan.Operation.Monochrome{},
               %Plan.Operation.Duotone{},
               %Plan.Operation.Brightness{},
               %Plan.Operation.Contrast{},
               %Plan.Operation.Saturation{},
               %Plan.Operation.Colorize{},
               %Plan.Operation.Gradient{}
             ] = ops
    end

    test "every effect's identity point emits nothing" do
      # Each of these is a distinct per-effect guard in plan_builder; dropping any
      # one of them emits an op the framework arm does not.
      assert {:ok, []} =
               assert_arms_agree(
                 effects: [
                   blur: 0.0,
                   sharpen: 0.0,
                   pixelate: 1,
                   monochrome: [intensity: {:ratio, 0, 1}],
                   duotone: [intensity: {:ratio, 0, 1}],
                   brightness: 0,
                   contrast: 1.0,
                   saturation: 1.0,
                   colorize: [opacity: {:ratio, 0, 1}],
                   gradient: [opacity: {:ratio, 0, 1}]
                 ]
               )

      assert {:ok, []} = assert_arms_agree(effects: [pixelate: 0])
    end
  end

  describe "stage 6: canvas" do
    test "extend emits a canvas sized by the resize box" do
      assert_arms_agree(@capped ++ [extend: true])
    end

    test "extend with a gravity and offsets" do
      assert_arms_agree(
        @capped ++
          [
            extend: true,
            extend_gravity: {:anchor, :right, :bottom},
            extend_x_offset: 3.0,
            extend_y_offset: 4.0
          ]
      )
    end

    test "every extend gravity anchor" do
      for x <- [:left, :center, :right], y <- [:top, :center, :bottom] do
        assert_arms_agree(@capped ++ [extend: true, extend_gravity: {:anchor, x, y}])
      end
    end

    test "an explicitly disabled extend emits nothing even with a gravity set" do
      assert_arms_agree(
        @capped ++
          [
            extend: false,
            extend_requested: true,
            extend_gravity: {:anchor, :center, :center}
          ]
      )
    end

    test "an extend implied by a gravity or offset alone" do
      assert_arms_agree(@capped ++ [extend_gravity: {:anchor, :left, :top}])
      assert_arms_agree(@capped ++ [extend_x_offset: 1.0])
      assert_arms_agree(@capped ++ [extend_y_offset: 1.0])
    end

    test "extend_aspect_ratio emits its own canvas" do
      assert_arms_agree(@capped ++ [extend_aspect_ratio: true])
    end

    test "extend_aspect_ratio with a gravity and offsets" do
      assert_arms_agree(
        @capped ++
          [
            extend_aspect_ratio: true,
            extend_aspect_ratio_gravity: {:anchor, :left, :top},
            extend_aspect_ratio_x_offset: 8.0,
            extend_aspect_ratio_y_offset: 9.0
          ]
      )
    end

    test "extend_aspect_ratio without a resolvable target ratio emits nothing" do
      assert {:ok, [%Plan.Operation.Resize{}]} =
               assert_arms_agree(width: {:pixels, 800}, extend_aspect_ratio: true)
    end

    test "both canvases at once, extend first" do
      assert {:ok, ops} = assert_arms_agree(@capped ++ [extend: true, extend_aspect_ratio: true])

      assert [
               %Plan.Operation.Resize{},
               %Plan.Operation.Canvas{},
               %Plan.Operation.Canvas{}
             ] = ops
    end

    test "a canvas dimension follows the same zero-sentinel rule as the resize" do
      assert_arms_agree(width: {:pixels, 0}, height: {:pixels, 600}, dpr: 2.0, extend: true)
    end
  end

  describe "stage 7: padding" do
    test "an all-zero padding emits nothing" do
      assert {:ok, []} = assert_arms_agree(padding_top: 0)
    end

    test "each side alone" do
      for side <- [:padding_top, :padding_right, :padding_bottom, :padding_left] do
        assert_arms_agree([{side, 10}])
      end
    end

    test "the marker's fallback is the request's own dpr ratio" do
      for dpr <- [nil, 1.0, 2.0, 0.5, 1.5, 3.7] do
        fields = if dpr, do: [dpr: dpr, padding_top: 10], else: [padding_top: 10]
        assert_arms_agree(fields)
      end
    end

    test "the marker's mode is :canvas_preserving when an extend emits" do
      assert_arms_agree(@capped ++ [padding_top: 10, extend: true])
      assert_arms_agree(@capped ++ [padding_top: 10, extend_aspect_ratio: true])
    end

    test "the marker's mode is :resize otherwise" do
      assert_arms_agree(@capped ++ [padding_top: 10])
      assert_arms_agree(width: {:pixels, 800}, padding_top: 10, extend_aspect_ratio: true)
    end
  end

  describe "stage 8: background" do
    test "a background color emits a background operation" do
      assert_arms_agree(background_color: color!(255, 128, 0))
    end

    test "no background color emits nothing" do
      assert {:ok, []} = assert_arms_agree(background_color: nil)
    end
  end

  describe "the whole 8-stage chain" do
    test "an empty request yields no operations" do
      assert {:ok, []} = assert_arms_agree([])
    end

    test "a request touching all eight stages yields them in plan_builder's order" do
      assert {:ok, ops} =
               assert_arms_agree(
                 trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
                 orientation: [rotate: 90, flip: :vertical],
                 crop: [width: {:pixels, 400}, height: {:pixels, 300}],
                 width: {:pixels, 200},
                 height: {:pixels, 150},
                 resizing_type: :force,
                 enlarge: false,
                 dpr: 2.0,
                 effects: [blur: 2.0],
                 extend: true,
                 extend_aspect_ratio: true,
                 padding_top: 10,
                 background_color: color!(1, 2, 3)
               )

      assert [
               %Plan.Operation.Trim{},
               %Plan.Operation.Rotate{},
               %Plan.Operation.Flip{},
               %Plan.Operation.CropGuided{},
               %Plan.Operation.Resize{},
               %Plan.Operation.Blur{},
               %Plan.Operation.Canvas{},
               %Plan.Operation.Canvas{},
               %Plan.Operation.Padding{},
               %Plan.Operation.Background{}
             ] = ops
    end
  end

  # --- the D5 divergence, asserted directly -------------------------------

  describe "the {:effective, …} marker is never constructed [spec D5]" do
    test "a padding+dpr request emits a concrete pixel ratio" do
      assert {:ok, ops} = dialect_operations(dpr: 2.0, padding_top: 10)
      assert [%Padding{} = padding] = Enum.filter(ops, &match?(%Padding{}, &1))

      assert match?({:ratio, _, _}, padding.pixel_ratio)
      refute match?({:effective, _, _}, padding.pixel_ratio)
    end

    test "no operation of any stage carries an effective marker" do
      assert {:ok, ops} =
               dialect_operations(
                 @capped ++ [dpr: 2.0, padding_top: 10, extend: true, extend_aspect_ratio: true]
               )

      refute Enum.any?(ops, fn op ->
               op
               |> Map.from_struct()
               |> Map.values()
               |> Enum.any?(&match?({:effective, _, _}, &1))
             end)
    end
  end
end

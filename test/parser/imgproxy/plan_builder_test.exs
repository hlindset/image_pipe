defmodule ImagePipe.Parser.Imgproxy.PlanBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Format
  alias ImagePipe.Parser.Imgproxy.Effects
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.PipelineRequest
  alias ImagePipe.Parser.Imgproxy.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  test "converts one imgproxy pipeline request into a product-neutral plan" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: output_request()
    }

    assert {:ok,
            %Plan{
              source: %Source.Path{segments: ["images", "cat.jpg"]},
              pipelines: [
                %Pipeline{operations: operations}
              ],
              output: %Output{mode: :automatic}
            }} = PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :fit} = params] = operations
    assert params.width == pixels(300)
    assert params.height == auto()
    assert params.dpr == ratio(1, 1)
    assert params.enlargement == :deny
  end

  test "plans fit requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: false)

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :deny

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: true)

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :allow
  end

  test "plans fill requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: false
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :deny
    assert anchor(resize.guide) == {:center, :center}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: true
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :allow
    assert anchor(resize.guide) == {:center, :center}
  end

  test "plans gravity-bearing fill, fill-down, and auto with result crop operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :left, :top}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert anchor(resize.guide) == {:left, :top}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:fp, 0.25, 0.75}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert focal_point(resize.guide) == {1, 4, 3, 4}
    assert resize.enlargement == :deny

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :auto,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom}
             )

    assert [%Operation.Resize{mode: :auto} = resize] = operations
    assert anchor(resize.guide) == {:right, :bottom}
  end

  test "preserves zero fit and fill dimensions as no geometry when both dimensions are auto" do
    for resizing_type <- [:fit, :fill] do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
               plan_pipeline(
                 resizing_type: resizing_type,
                 width: {:pixels, 0},
                 height: {:pixels, 0}
               )
    end
  end

  test "plans zero dimensions with meaningful min resize rules" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             plan_pipeline(
               width: {:pixels, 0},
               height: {:pixels, 0},
               min_width: {:pixels, 300}
             )

    assert resize.width == auto()
    assert resize.height == auto()
    assert resize.min_width == pixels(300)
  end

  test "normalizes single zero fit dimensions to auto resize dimensions" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 0}, height: {:pixels, 200})

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == auto()
    assert resize.height == pixels(200)
  end

  test "plans force requests with one zero dimension as source-preserving auto dimensions" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :stretch} = resize]}]
            }} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200})

    assert resize.width == auto()
    assert resize.height == pixels(200)

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :stretch} = resize]}]
            }} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0})

    assert resize.width == pixels(300)
    assert resize.height == auto()
  end

  test "plans fit, fill-down, force, and auto as product-neutral resize operations" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}
              ]
            }} =
             plan_pipeline(resizing_type: :fit, width: {:pixels, 100}, height: {:pixels, 0})

    assert resize.width == pixels(100)
    assert resize.height == auto()

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{mode: :cover} = down
                  ]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100}
             )

    assert down.enlargement == :deny
    # fill-down is a :cover resize distinguished by the `down` flag — it never upscales
    # and crops to the requested aspect ratio when the source is smaller than the box.
    assert down.down == true

    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :cover} = fill]}]}} =
             plan_pipeline(resizing_type: :fill, width: {:pixels, 100}, height: {:pixels, 100})

    assert fill.down == false

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{mode: :auto}
                  ]
                }
              ]
            }} =
             plan_pipeline(resizing_type: :auto, width: {:pixels, 100}, height: {:pixels, 100})
  end

  test "plans extend as neutral canvas operation" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 100}, height: {:pixels, 100}, extend: true)

    assert Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "exar emits a canvas ratio derived from the resize target" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]} = plan} =
             plan_pipeline(
               width: {:pixels, 1600},
               height: {:pixels, 900},
               extend_aspect_ratio: true
             )

    assert Enum.any?(operations, fn
             %Operation.Canvas{width: {:ratio, 1600, 1}, height: {:ratio, 900, 1}} -> true
             _ -> false
           end)

    assert {:ok, _pipelines} = ImagePipe.Transform.validate_prefetch_safe_plan(plan)
  end

  test "exar is a no-op when a resize dimension is not set" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 1600},
               extend_aspect_ratio: true
             )

    refute Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "plans extend gravity and offsets as neutral canvas operation fields" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: true,
               extend_gravity: {:anchor, :left, :top},
               extend_x_offset: 5.0,
               extend_y_offset: -3.0
             )

    assert %Operation.Canvas{
             placement: placement,
             x_offset: 5.0,
             y_offset: -3.0
           } = List.last(operations)

    assert placement == :top_left
  end

  test "plans basic effects after geometry and before composition operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               padding_top: 2,
               background_color: color!(10, 20, 30),
               blur: 2.5,
               sharpen: 0.7,
               pixelate: 8,
               monochrome: [intensity: ratio(1, 2), color: color!(255, 204, 0)],
               duotone: [
                 intensity: ratio(1, 4),
                 shadow: color!(17, 34, 51),
                 highlight: color!(255, 238, 204)
               ],
               brightness: 20,
               contrast: 1.5,
               saturation: 2.0
             )

    assert [
             %Operation.Resize{},
             blur,
             sharpen,
             pixelate,
             monochrome,
             duotone,
             brightness,
             contrast,
             saturation,
             %Operation.Padding{},
             %Operation.Background{}
           ] = operations

    assert blur.__struct__ == ImagePipe.Plan.Operation.Blur
    assert blur.sigma == 2.5
    assert sharpen.__struct__ == ImagePipe.Plan.Operation.Sharpen
    assert sharpen.sigma == 0.7
    assert pixelate.__struct__ == ImagePipe.Plan.Operation.Pixelate
    assert pixelate.size == 8
    assert monochrome.__struct__ == ImagePipe.Plan.Operation.Monochrome
    assert monochrome.intensity == ratio(1, 2)
    assert duotone.__struct__ == ImagePipe.Plan.Operation.Duotone
    assert duotone.intensity == ratio(1, 4)
    assert brightness.__struct__ == ImagePipe.Plan.Operation.Brightness
    assert brightness.value == 20
    assert contrast.__struct__ == ImagePipe.Plan.Operation.Contrast
    assert contrast.value == 1.5
    assert saturation.__struct__ == ImagePipe.Plan.Operation.Saturation
    assert saturation.value == 2.0
  end

  test "skips imgproxy effect no-op values" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               blur: 0.0,
               sharpen: 0.0,
               pixelate: 0,
               monochrome: [intensity: ratio(0, 1)],
               duotone: [intensity: ratio(0, 1)],
               brightness: 0,
               contrast: 1.0,
               saturation: 1.0
             )

    assert operations == []

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(pixelate: 1)

    assert operations == []
  end

  test "colorize plans after saturation" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               saturation: 1.5,
               colorize: [opacity: ratio(1, 2), color: color!(0, 0, 0)]
             )

    assert [%Operation.Saturation{}, %Operation.Colorize{}] = ops
  end

  test "colorize opacity 0 is a no-op" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(colorize: [opacity: ratio(0, 1)])
  end

  test "gradient plans after colorize" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               colorize: [opacity: ratio(1, 2), color: color!(0, 0, 0)],
               gradient: [opacity: ratio(1, 2), color: color!(0, 0, 0), angle: 0.0]
             )

    assert [%Operation.Colorize{}, %Operation.Gradient{}] = ops
  end

  test "gradient opacity 0 is a no-op" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(gradient: [opacity: ratio(0, 1)])
  end

  test "explicit false extend prevents parsed extend tails from planning canvas operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: false,
               extend_requested: true,
               extend_gravity: {:anchor, :center, :center},
               extend_x_offset: 5.0,
               extend_y_offset: -3.0
             )

    refute Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "plans top-level gravity offsets into result crop resize fields" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 12.0},
               gravity_y_offset: {:scale, -0.25}
             )

    assert anchor(crop.guide) == {:right, :bottom}
    # Raw offsets: the executable crop applies the per-axis sign (subtract for the
    # far :right/:bottom edges), so the parser no longer pre-negates (#146 Bug 3).
    assert crop.x_offset == {:pixels, 12.0}
    assert crop.y_offset == {:scale, -0.25}
  end

  test "plans dpr with semantic resize guide and adjusted offsets" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               dpr: 2.0,
               gravity: {:anchor, :right, :center},
               gravity_x_offset: {:pixels, 12.0},
               gravity_y_offset: {:scale, -0.25}
             )

    assert crop.dpr == ratio(2, 1)
    assert anchor(crop.guide) == {:right, :center}
    # Raw offsets (#146 Bug 3): no parser pre-negation; the executable subtracts on
    # the far :right edge and the :center Y axis adds.
    assert crop.x_offset == {:pixels, 12.0}
    assert crop.y_offset == {:scale, -0.25}
  end

  test "plans top-level gravity offsets into auto result crop resize fields" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :auto} = crop]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :auto,
               width: {:pixels, 100},
               height: {:pixels, 50},
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 8.0},
               gravity_y_offset: {:scale, -0.5}
             )

    assert anchor(crop.guide) == {:right, :bottom}
    # Raw offsets (#146 Bug 3): executable applies the per-axis far-edge subtraction.
    assert crop.x_offset == {:pixels, 8.0}
    assert crop.y_offset == {:scale, -0.5}
  end

  test "crop without explicit gravity inherits top-level gravity type and offsets" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               gravity: {:anchor, :left, :top},
               gravity_x_offset: {:pixels, 120.0},
               gravity_y_offset: {:pixels, 80.0},
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: nil
               }
             )

    assert crop.guide == :top_left
    assert crop.x_offset == {:pixels, 120.0}
    assert crop.y_offset == {:pixels, 80.0}
  end

  test "inline crop gravity uses its own offsets, not the top-level gravity offsets" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 120.0},
               gravity_y_offset: {:pixels, 80.0},
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:anchor, :left, :top}
               }
             )

    assert crop.guide == :top_left
    assert crop.x_offset == {:pixels, 0.0}
    assert crop.y_offset == {:pixels, 0.0}
  end

  test "plans crop focal-point gravity and relative offsets" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:fp, 0.25, 0.75},
                 x_offset: {:scale, 0.25},
                 y_offset: {:pixels, -12.0}
               }
             )

    assert focal_point(crop.guide) == {1, 4, 3, 4}
    assert crop.x_offset == {:scale, 0.25}
    assert crop.y_offset == {:pixels, -12.0}
  end

  test "car populates CropGuided aspect_ratio and enlarge" do
    pipeline =
      plan_pipeline(
        crop: %ImagePipe.Parser.Imgproxy.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 200}
        },
        crop_aspect_ratio: 1.0,
        crop_aspect_ratio_enlarge: true
      )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} = pipeline

    assert Enum.any?(operations, fn
             %ImagePipe.Plan.Operation.CropGuided{aspect_ratio: {:ratio, 1, 1}, enlarge: true} ->
               true

             _ ->
               false
           end)
  end

  test "car:0 yields no aspect-ratio correction" do
    pipeline =
      plan_pipeline(
        crop: %ImagePipe.Parser.Imgproxy.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 200}
        },
        crop_aspect_ratio: 0.0
      )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} = pipeline

    assert Enum.any?(operations, fn
             %ImagePipe.Plan.Operation.CropGuided{aspect_ratio: nil} -> true
             _ -> false
           end)
  end

  test "planner emits fixed orientation crop resize order independent of URL order" do
    one =
      plan_pipeline(
        crop: %ImagePipe.Parser.Imgproxy.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 100}
        },
        rotate: 90,
        width: {:pixels, 200}
      )

    two =
      plan_pipeline(
        width: {:pixels, 200},
        rotate: 90,
        crop: %ImagePipe.Parser.Imgproxy.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 100}
        }
      )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: one_ops}]}} = one
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: two_ops}]}} = two

    assert operation_names(one_ops) == operation_names(two_ops)

    assert operation_names(one_ops) == [:rotate, :crop_guided, {:resize, :fit}]

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               auto_orient: true,
               rotate: 90,
               flip: :horizontal,
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100}
               },
               width: {:pixels, 200}
             )

    assert operation_names(operations) == [
             :rotate,
             :flip,
             :crop_guided,
             {:resize, :fit}
           ]
  end

  test "planner emits fixed fill result crop before canvas extension" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom},
               extend: true
             )

    assert operation_names(operations) == [{:resize, :cover}, :canvas]
  end

  test "plans padding after canvas and before background composition" do
    assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: true,
               padding_top: 1,
               padding_right: 2,
               padding_bottom: 3,
               padding_left: 4,
               background_color: red
             )

    assert [
             %Operation.Resize{},
             %Operation.Canvas{fill: :transparent},
             %Operation.Padding{
               top: {:px, 1},
               right: {:px, 2},
               bottom: {:px, 3},
               left: {:px, 4},
               fill: :transparent,
               pixel_ratio: {:effective, {:ratio, 1, 1}, :canvas_preserving}
             },
             %Operation.Background{color: ^red}
           ] = operations
  end

  test "padding no-op forms emit no padding operation" do
    for attrs <- [
          [padding_top: 0, padding_right: 0, padding_bottom: 0, padding_left: 0]
        ] do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} = plan_pipeline(attrs)
      refute Enum.any?(operations, &match?(%Operation.Padding{}, &1))
    end
  end

  test "padding carries requested DPR as fallback for effective pixel ratio" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%Operation.Resize{}, %Operation.Padding{} = padding]}
              ]
            }} =
             plan_pipeline(width: {:pixels, 100}, dpr: 1.5, padding_top: 2)

    assert padding.pixel_ratio == {:effective, {:ratio, 3, 2}, :resize}
  end

  test "padding planned with extend uses canvas-preserving effective pixel ratio" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{},
                    %Operation.Canvas{},
                    %Operation.Padding{} = padding
                  ]
                }
              ]
            }} =
             plan_pipeline(
               width: {:pixels, 200},
               height: {:pixels, 100},
               dpr: 0.5,
               extend: true,
               padding_top: 10
             )

    assert padding.pixel_ratio == {:effective, {:ratio, 1, 2}, :canvas_preserving}
  end

  test "background unset or cleared emits no background operation" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(background_color: nil)

    refute Enum.any?(operations, &match?(%Operation.Background{}, &1))
  end

  test "plans neutral resize rule inputs before no-op operations" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             plan_pipeline(
               min_width: {:pixels, 100},
               min_height: {:pixels, 80},
               zoom_x: 2.0,
               zoom_y: 2.0,
               dpr: 2.0
             )

    assert resize.min_width == pixels(100)
    assert resize.min_height == pixels(80)
    assert resize.zoom_x == 2.0
    assert resize.zoom_y == 2.0
    assert resize.dpr == ratio(2, 1)
  end

  # #203 Tier 3 — zero/auto-dim and DPR dimension rules settled at the planner layer
  # against imgproxy's `prepare.go` geometry. T3.6 in particular can't be a pixel
  # fixture: its dpr-scaled output dims diverge from any committable baseline and
  # `pixel_compare` raises on a dims mismatch.

  test "exar gates off on a single zero/auto dimension while min-dims stay live (T3.3)" do
    # imgproxy applies extend-aspect-ratio only when both target dims are > 0
    # (`prepare.go`: `c.TargetWidth > 0 && c.TargetHeight > 0`); ImagePipe's
    # `resize_target_ratio` carries the same `w > 0 and h > 0` guard, so a single
    # zero/auto dim emits no canvas. `rs:fit:300:0/exar:1` → resize only.
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               width: {:pixels, 300},
               height: {:pixels, 0},
               extend_aspect_ratio: true
             )

    assert [%Operation.Resize{mode: :fit} = resize] = ops
    assert resize.width == pixels(300)
    assert resize.height == auto()
    refute Enum.any?(ops, &match?(%Operation.Canvas{}, &1))

    # Min-dims are NOT gated by a zero dim — imgproxy applies minWidth/minHeight
    # unconditionally in `calcScale` (`prepare.go`). `rs:fit:0:200/mw:280` keeps mw.
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = min_resize]}]}} =
             plan_pipeline(
               width: {:pixels, 0},
               height: {:pixels, 200},
               min_width: {:pixels, 280}
             )

    assert min_resize.width == auto()
    assert min_resize.height == pixels(200)
    assert min_resize.min_width == pixels(280)
  end

  test "raw fit + dpr folds into the resize with no canvas wrapper (T3.6)" do
    # `rs:fit:300:200/dpr:2` carries the DPR on the resize itself (final 600x400);
    # no extend/padding wrapper means the output dims diverge from a 300x200 baseline,
    # so it can only be settled here, not as a pixel fixture.
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               resizing_type: :fit,
               width: {:pixels, 300},
               height: {:pixels, 200},
               dpr: 2.0
             )

    assert [%Operation.Resize{mode: :fit} = resize] = ops
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.dpr == ratio(2, 1)
    refute Enum.any?(ops, &match?(%Operation.Canvas{}, &1))
    refute Enum.any?(ops, &match?(%Operation.Padding{}, &1))
  end

  test "plans parsed crop and orientation semantics before no-op operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{}]}]}} =
             plan_pipeline(crop: struct(ImagePipe.Parser.Imgproxy.CropRequest))

    # EXIF auto-orient is no longer a pipeline op; it surfaces as Plan.auto_rotate
    # and the orientation block contributes no operations on its own.
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(
               orientation: struct(ImagePipe.Parser.Imgproxy.Orientation, auto_orient: true)
             )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(orientation_requested: true)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               crop: struct(ImagePipe.Parser.Imgproxy.CropRequest),
               orientation: struct(ImagePipe.Parser.Imgproxy.Orientation, auto_orient: true)
             )

    assert operation_names(operations) == [:crop_guided]
  end

  test "converts multiple imgproxy pipeline requests into separate product-neutral pipelines" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [
        %PipelineRequest{width: {:pixels, 500}},
        %PipelineRequest{height: {:pixels, 200}}
      ],
      output: output_request()
    }

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :fit} = first_params] = first_operations
    assert first_params.width == pixels(500)
    assert first_params.height == auto()

    assert [%Operation.Resize{mode: :fit} = second_params] = second_operations
    assert second_params.width == auto()
    assert second_params.height == pixels(200)
  end

  test "maps smart gravity fill resize to the smart plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: :sm
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.guide == :smart
  end

  test "maps smart gravity crop to the smart plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: :sm
               }
             )

    assert crop.guide == :smart
  end

  test "g:sm with smart_crop_face_detection becomes {:smart, :face_assist}" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               [
                 resizing_type: :fill,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: :sm
               ],
               imgproxy: [smart_crop_face_detection: true]
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.guide == {:smart, :face_assist}
  end

  test "g:sm crop with smart_crop_face_detection becomes {:smart, :face_assist}" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               [
                 crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: :sm
                 }
               ],
               imgproxy: [smart_crop_face_detection: true]
             )

    assert crop.guide == {:smart, :face_assist}
  end

  test "g:sm without the flag stays :smart" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               [
                 resizing_type: :fill,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: :sm
               ],
               imgproxy: [smart_crop_face_detection: false]
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.guide == :smart
  end

  test "maps face object gravity fill resize to the detect plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, ["face"]}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.guide == {:detect, {["face"], %{}}}
  end

  test "maps face object gravity crop to the detect plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, ["face"]}
               }
             )

    assert crop.guide == {:detect, {["face"], %{}}}
  end

  test "planner emits only product-neutral guide terms (no dialect leak)" do
    for {gravity, expected_guide} <- [
          {:sm, :smart},
          {{:obj, ["face"]}, {:detect, {["face"], %{}}}}
        ] do
      assert {:ok, %Plan{pipelines: pipelines}} =
               plan_pipeline(
                 resizing_type: :fill,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: gravity
               )

      guides =
        for pipeline <- pipelines,
            operation <- pipeline.operations,
            guide = Map.get(operation, :guide),
            not is_nil(guide),
            do: guide

      assert expected_guide in guides
      refute Enum.any?(guides, &match?({:obj, _}, &1))
      refute :sm in guides
    end
  end

  test "bare object gravity maps to detect :all (fill path)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, []}
             )

    assert resize.guide == {:detect, {:all, %{}}}
  end

  test "the all pseudo-class maps to detect :all (fill path)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, ["all"]}
             )

    assert resize.guide == {:detect, {:all, %{}}}
  end

  test "multi-class object gravity maps to detect with those classes (fill path)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, ["face", "cat"]}
             )

    assert resize.guide == {:detect, {["face", "cat"], %{}}}
  end

  # Behavior change: numeric trailing tokens are now unknown classes dropped at
  # routing, NOT an error. g:obj:face:5:5 -> {:detect, ["face", "5", "5"]} where
  # "5" is an unknown class dropped later at routing (object gravity has no offsets).
  test "object gravity with numeric tokens treats them as (unknown) classes, not an error (crop path)" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]
            }} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, ["face", "5", "5"]}
               }
             )

    assert crop.guide == {:detect, {["face", "5", "5"], %{}}}
  end

  test "all among classes collapses to :all (fill path)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, ["car", "all"]}
             )

    assert resize.guide == {:detect, {:all, %{}}}
  end

  test "bare object gravity maps to detect :all (crop path)" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]
            }} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, []}
               }
             )

    assert crop.guide == {:detect, {:all, %{}}}
  end

  test "the all pseudo-class maps to detect :all (crop path)" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]
            }} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, ["all"]}
               }
             )

    assert crop.guide == {:detect, {:all, %{}}}
  end

  test "multi-class object gravity maps to detect with those classes (crop path)" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]
            }} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, ["car", "dog"]}
               }
             )

    assert crop.guide == {:detect, {["car", "dog"], %{}}}
  end

  test "represents output intent outside imgproxy pipeline operations" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [
        %PipelineRequest{
          resizing_type: :force,
          width: {:pixels, 300},
          height: {:pixels, 200}
        }
      ],
      output: output_request(format: :webp)
    }

    assert {:ok,
            %ImagePipe.Plan{
              pipelines: [%ImagePipe.Plan.Pipeline{operations: operations}],
              output: %ImagePipe.Plan.Output{mode: :automatic}
            }} =
             PlanBuilder.to_plan(
               %ParsedRequest{request | output: output_request()},
               []
             )

    assert [%Operation.Resize{mode: :stretch} = automatic_params] = operations
    assert automatic_params.width == pixels(300)
    assert automatic_params.height == pixels(200)

    assert {:ok,
            %ImagePipe.Plan{
              pipelines: [%ImagePipe.Plan.Pipeline{operations: operations}],
              output: %ImagePipe.Plan.Output{mode: {:explicit, :webp}}
            }} =
             PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :stretch} = explicit_params] = operations
    assert explicit_params.width == pixels(300)
    assert explicit_params.height == pixels(200)
  end

  property "output format does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePipe.Plan{} = automatic_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{
                   parsed_request
                   | output: output_request()
                 },
                 []
               )

      assert automatic_plan.output.mode == :automatic
      assert [%ImagePipe.Plan.Pipeline{} | _] = automatic_plan.pipelines

      for format <- Format.output_formats() do
        assert {:ok, %ImagePipe.Plan{} = explicit_plan} =
                 PlanBuilder.to_plan(
                   %ParsedRequest{
                     parsed_request
                     | output: output_request(format: format)
                   },
                   []
                 )

        assert explicit_plan.output.mode == {:explicit, format}
        assert explicit_plan.pipelines == automatic_plan.pipelines

        # Shared output fields (strip_metadata/keep_copyright/color_profile)
        # must not diverge between automatic and explicit output modes.
        assert Map.drop(Map.from_struct(explicit_plan.output), [:mode]) ==
                 Map.drop(Map.from_struct(automatic_plan.output), [:mode])
      end
    end
  end

  property "output quality does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePipe.Plan{} = default_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{
                   parsed_request
                   | output: output_request()
                 },
                 []
               )

      quality_request =
        output_request(
          quality: {:quality, 80},
          format_qualities: %{webp: {:quality, 70}}
        )

      assert {:ok,
              %ImagePipe.Plan{
                output: %ImagePipe.Plan.Output{
                  mode: :automatic,
                  quality: {:quality, 80},
                  format_qualities: %{webp: {:quality, 70}}
                }
              } = quality_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{parsed_request | output: quality_request},
                 []
               )

      assert quality_plan.pipelines == default_plan.pipelines
    end
  end

  test "threads quality_search and max_bytes onto the automatic output plan" do
    search = %QualitySearch.Ssimulacra2{
      target: 90.0,
      min_quality: 70,
      max_quality: 80
    }

    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: output_request(quality_search: search, max_bytes: 51_200)
    }

    assert {:ok,
            %Plan{
              output: %Output{
                mode: :automatic,
                quality_search: ^search,
                max_bytes: 51_200
              }
            }} = PlanBuilder.to_plan(request, [])
  end

  test "threads quality_search and max_bytes onto the explicit-format output plan" do
    search = %QualitySearch.Ssimulacra2{
      target: 90.0,
      min_quality: 70,
      max_quality: 80
    }

    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: output_request(format: :webp, quality_search: search, max_bytes: 51_200)
    }

    assert {:ok,
            %Plan{
              output: %Output{
                mode: {:explicit, :webp},
                quality_search: ^search,
                max_bytes: 51_200
              }
            }} = PlanBuilder.to_plan(request, [])
  end

  test "projects imgproxy request facets into product-neutral plan facets" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: output_request(format: :webp),
      policy: policy_request(),
      cache: cache_request(cachebuster: "v1"),
      response: response_request(filename: "cat", disposition: :attachment)
    }

    assert {:ok,
            %Plan{
              output: %ImagePipe.Plan.Output{mode: {:explicit, :webp}},
              expires: 0,
              cachebuster: "v1",
              response: %Response{
                filename: "cat",
                disposition: :attachment
              }
            }} = PlanBuilder.to_plan(request, clock: fn -> ~U[2026-05-05 12:00:00Z] end)
  end

  test "carries the response debug? flag onto the plan, defaulting off" do
    base = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{}],
      output: output_request()
    }

    assert {:ok, %Plan{response: %Response{debug?: false}}} = PlanBuilder.to_plan(base, [])

    debug = %{base | response: response_request(debug?: true)}
    assert {:ok, %Plan{response: %Response{debug?: true}}} = PlanBuilder.to_plan(debug, [])
  end

  test "derives response filename stem from source basename when omitted" do
    assert {:ok,
            %Plan{
              response: %Response{
                filename: "cat"
              }
            }} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: "images/cat.jpg",
               pipelines: [%PipelineRequest{}],
               output: output_request()
             })

    assert PlanBuilder.to_plan(%ParsedRequest{
             signature: "_",
             source_kind: :plain,
             source_path: "images/",
             pipelines: [%PipelineRequest{}],
             output: output_request()
           }) == {:error, :invalid_source_path}
  end

  test "rejects invalid explicit response filenames" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: "images/cat.jpg",
      pipelines: [%PipelineRequest{}],
      output: output_request(),
      response: response_request(filename: "../cat", disposition: :attachment)
    }

    assert PlanBuilder.to_plan(request, []) == {:error, {:invalid_filename, "../cat"}}
  end

  test "objw maps to detect :all with a canonical weights map" do
    assert objw_guide([{"all", 1.0}, {"face", 3.0}]) == {:detect, {:all, %{"face" => 3.0}}}
  end

  test "objw all-baseline above 1 is carried; a class equal to default is dropped" do
    assert objw_guide([{"all", 3.0}, {"car", 3.0}]) == {:detect, {:all, %{default: 3.0}}}
  end

  test "objw all-baseline with a below-default class" do
    assert objw_guide([{"all", 3.0}, {"car", 1.0}]) ==
             {:detect, {:all, %{"car" => 1.0, default: 3.0}}}
  end

  test "objw:face:3 filters to face class; objw:all:1:face:3 detects all — they differ" do
    # objw:face:3 — named class forms the detection spec, not :all
    assert objw_guide([{"face", 3.0}]) == {:detect, {["face"], %{"face" => 3.0}}}
    # objw:all:1:face:3 — all broadens spec to :all; all:1 drops as default
    assert objw_guide([{"all", 1.0}, {"face", 3.0}]) == {:detect, {:all, %{"face" => 3.0}}}
    # They are NOT equivalent
    refute objw_guide([{"face", 3.0}]) == objw_guide([{"all", 1.0}, {"face", 3.0}])
  end

  test "objw named classes form the detection spec (filter, like obj)" do
    # objw:person:2:face:3 — spec is the class list, weights carry the values
    assert objw_guide([{"person", 2.0}, {"face", 3.0}]) ==
             {:detect, {["person", "face"], %{"person" => 2.0, "face" => 3.0}}}

    # objw:face:1 — weight equals default (1), drops from map; spec is ["face"] (not :all)
    # This is equivalent in behavior to obj:face, and its guide should match
    assert objw_guide([{"face", 1.0}]) == {:detect, {["face"], %{}}}
  end

  test "objw uniform weights canonicalize to an empty map" do
    assert objw_guide([{"all", 1.0}, {"face", 1.0}]) == {:detect, {:all, %{}}}
  end

  test "objw maps identically through the crop path (no fill/crop divergence)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:objw, [{"all", 2.0}, {"face", 3.0}]}
               }
             )

    assert crop.guide == {:detect, {:all, %{"face" => 3.0, default: 2.0}}}
  end

  property "objw canonicalization is order-independent" do
    check all classes <-
                uniq_list_of(
                  member_of(["face", "car", "dog", "person", "cat", "bus", "truck", "bird"]),
                  min_length: 1,
                  max_length: 3
                ),
              weights <- list_of(member_of([1.0, 2.0, 3.0]), length: length(classes)),
              default <- member_of([1.0, 2.0, 3.0]) do
      pairs = [{"all", default} | Enum.zip(classes, weights)]
      assert objw_guide(pairs) == objw_guide(Enum.shuffle(pairs))
    end
  end

  property "objw canonicalization is idempotent with all-broadened spec (re-feeding canonical map)" do
    check all classes <-
                uniq_list_of(
                  member_of(["face", "car", "dog", "person", "cat", "bus", "truck", "bird"]),
                  min_length: 1,
                  max_length: 3
                ),
              weights <- list_of(member_of([1.0, 2.0]), length: length(classes)),
              default <- member_of([1.0, 2.0]) do
      # Always include "all" so spec stays :all throughout the round-trip.
      pairs = [{"all", default} | Enum.zip(classes, weights)]
      {:detect, {:all, map}} = objw_guide(pairs)
      # Rebuild pairs from the canonical map (default → "all") and re-canonicalize.
      # Must include "all" in the repairs to preserve the :all spec.
      repairs =
        [
          {"all", Map.get(map, :default, 1.0)}
          | Enum.map(map, fn
              {:default, _w} -> nil
              {class, w} -> {class, w}
            end)
        ]
        |> Enum.reject(&is_nil/1)

      assert objw_guide(repairs) == {:detect, {:all, map}}
    end
  end

  test "trim is emitted first in geometry order" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
               width: {:pixels, 100},
               height: {:pixels, 100}
             )

    assert [%Operation.Trim{threshold: 10.0} | _rest] = ops
  end

  test "trim is emitted before orientation and resize operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             plan_pipeline(
               trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
               width: {:pixels, 100},
               height: {:pixels, 100},
               rotate: 90
             )

    assert [%Operation.Trim{}, %Operation.Rotate{}, %Operation.Resize{}] = ops
  end

  test "trim with dimensionless fill is rejected (fill requires at least one dimension)" do
    assert {:error, {:missing_dimensions, :fill}} =
             plan_pipeline(
               trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
               resizing_type: :fill,
               width: nil,
               height: nil
             )
  end

  defp objw_guide(pairs) do
    {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
      plan_pipeline(
        resizing_type: :fill,
        width: {:pixels, 100},
        height: {:pixels, 100},
        gravity: {:objw, pairs}
      )

    resize.guide
  end

  defp pixels(value), do: {:px, value}
  defp auto, do: :auto
  defp ratio(numerator, denominator), do: {:ratio, numerator, denominator}

  defp anchor(:center), do: {:center, :center}
  defp anchor({:anchor, x, y}), do: {x, y}

  defp focal_point(
         {:focal, {:ratio, x_numerator, x_denominator}, {:ratio, y_numerator, y_denominator}}
       ) do
    {x_numerator, x_denominator, y_numerator, y_denominator}
  end

  defp operation_names(operations), do: Enum.map(operations, &operation_name/1)

  defp operation_name(%Rotate{}), do: :rotate
  defp operation_name(%Flip{}), do: :flip
  defp operation_name(%Operation.CropGuided{}), do: :crop_guided
  defp operation_name(%Operation.Resize{mode: mode}), do: {:resize, mode}
  defp operation_name(%Operation.Canvas{}), do: :canvas
  defp operation_name(%Operation.Padding{}), do: :padding
  defp operation_name(%Operation.Background{}), do: :background

  defp parsed_request do
    map({valid_pipeline_request(), output_format()}, fn {pipeline_request, output_format} ->
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: "images/cat.jpg",
        pipelines: [pipeline_request],
        output: output_request(format: output_format)
      }
    end)
  end

  defp valid_pipeline_request do
    map(valid_geometry(), &struct!(PipelineRequest, &1))
  end

  defp valid_geometry do
    one_of([
      constant([]),
      map(fit_dimension(), &[width: &1]),
      map(fit_dimension(), &[height: &1]),
      map({fit_dimension(), fit_dimension()}, fn {width, height} ->
        [width: width, height: height]
      end),
      map({constant(:fill), fit_dimension(), fit_dimension()}, fn {resizing_type, width, height} ->
        [resizing_type: resizing_type, width: width, height: height]
      end),
      constant(resizing_type: :force),
      map({constant(:force), pixel_dimension(), one_of([pixel_dimension(), constant(nil)])}, fn
        {resizing_type, width, height} ->
          [resizing_type: resizing_type, width: width, height: height]
      end)
    ])
  end

  defp fit_dimension do
    map(integer(0..10_000), &{:pixels, &1})
  end

  defp pixel_dimension do
    map(integer(1..10_000), &{:pixels, &1})
  end

  defp output_format do
    one_of([constant(nil), member_of(Format.output_formats())])
  end

  defp plan_pipeline(attrs, opts \\ []) do
    attrs =
      attrs
      |> normalize_orientation_attrs()
      |> normalize_effect_attrs()

    PlanBuilder.to_plan(
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: "images/cat.jpg",
        pipelines: [struct!(PipelineRequest, attrs)],
        output: output_request()
      },
      opts
    )
  end

  defp normalize_orientation_attrs(attrs) do
    {auto_orient, attrs} = Keyword.pop(attrs, :auto_orient)
    {rotate, attrs} = Keyword.pop(attrs, :rotate)
    {flip, attrs} = Keyword.pop(attrs, :flip)

    orientation_attrs =
      []
      |> maybe_put(:auto_orient, auto_orient)
      |> maybe_put(:rotate, rotate)
      |> maybe_put(:flip, flip)

    if orientation_attrs == [] do
      attrs
    else
      {orientation, attrs} =
        Keyword.pop(attrs, :orientation, %ImagePipe.Parser.Imgproxy.Orientation{})

      Keyword.put(attrs, :orientation, struct!(orientation, orientation_attrs))
    end
  end

  defp normalize_effect_attrs(attrs) do
    {effect_attrs, attrs} =
      Keyword.split(attrs, [
        :blur,
        :sharpen,
        :pixelate,
        :monochrome,
        :duotone,
        :brightness,
        :contrast,
        :saturation,
        :colorize,
        :gradient
      ])

    if effect_attrs == [] do
      attrs
    else
      Keyword.put(attrs, :effects, struct!(Effects, effect_attrs))
    end
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Keyword.put(attrs, key, value)

  defp color!(red, green, blue) do
    assert {:ok, color} = Operation.color(red, green, blue)
    color
  end

  defp output_request(attrs \\ []), do: ParsedRequest.output_request(attrs)
  defp policy_request(attrs \\ []), do: ParsedRequest.policy_request(attrs)
  defp cache_request(attrs), do: ParsedRequest.cache_request(attrs)
  defp response_request(attrs), do: ParsedRequest.response_request(attrs)
end

defmodule ImagePipe.Parser.IIIF.PlanBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.{Bitonal, CropGuided, CropRegion, Flip, Gray, Resize, Rotate}
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @source %SourcePath{segments: ["images", "beach.jpg"]}

  defp build(tokens), do: PlanBuilder.image_plan(@source, tokens, auto_rotate: true)

  test "region+size+rotation+gray emit ops in IIIF order" do
    {:ok, %Plan{pipelines: [%{operations: ops}], output: out}} =
      build(%{
        region: {:px, 0, 0, 200, 300},
        size: {:wh, 100, 150, false},
        rotation: {false, 90},
        quality: :gray,
        format: :png
      })

    assert [%CropRegion{}, %Resize{mode: :stretch}, %Rotate{angle: 90}, %Gray{}] = ops
    assert out.mode == {:explicit, :png}
  end

  test "size w, without ^ uses enlargement: :reject" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{enlargement: :reject}]}]}} =
      build(%{
        region: :full,
        size: {:w, 9999, false},
        rotation: {false, 0},
        quality: :default,
        format: :jpg
      })
  end

  test "^ size uses enlargement: :allow" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{enlargement: :allow}]}]}} =
      build(%{
        region: :full,
        size: {:w, 9999, true},
        rotation: {false, 0},
        quality: :default,
        format: :jpg
      })
  end

  test "full/max/0/default emits one resize op + explicit jpeg output" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{}]}], output: out, render: :image}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 0},
        quality: :default,
        format: :jpg
      })

    assert out.mode == {:explicit, :jpeg}
  end

  test "quality bitonal emits a Bitonal op last (after size)" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{}, %Bitonal{}]}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 0},
        quality: :bitonal,
        format: :jpg
      })
  end

  test "square region emits crop_guided with aspect_ratio 1:1" do
    {:ok, %Plan{pipelines: [%{operations: [%CropGuided{aspect_ratio: {:ratio, 1, 1}} | _]}]}} =
      build(%{
        region: :square,
        size: {:max, false},
        rotation: {false, 0},
        quality: :default,
        format: :png
      })
  end

  test "pct region emits crop_region with ratio coords" do
    {:ok, %Plan{pipelines: [%{operations: [%CropRegion{x: {:ratio, 10, 100}} | _]}]}} =
      build(%{
        region:
          {:pct, {:ratio, 10, 100}, {:ratio, 20, 100}, {:ratio, 50, 100}, {:ratio, 50, 100}},
        size: {:max, false},
        rotation: {false, 0},
        quality: :default,
        format: :png
      })
  end

  test "size h emits resize fit with auto width" do
    {:ok,
     %Plan{pipelines: [%{operations: [%Resize{mode: :fit, width: :auto, height: {:px, 400}}]}]}} =
      build(%{
        region: :full,
        size: {:h, 400, false},
        rotation: {false, 0},
        quality: :default,
        format: :png
      })
  end

  test "size confined emits resize fit" do
    {:ok,
     %Plan{
       pipelines: [%{operations: [%Resize{mode: :fit, width: {:px, 300}, height: {:px, 200}}]}]
     }} =
      build(%{
        region: :full,
        size: {:confined, 300, 200, false},
        rotation: {false, 0},
        quality: :default,
        format: :png
      })
  end

  test "size pct emits resize fit with zoom" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{zoom_x: zoom_x, zoom_y: zoom_y}]}]}} =
      build(%{
        region: :full,
        size: {:pct, {:ratio, 50, 100}, false},
        rotation: {false, 0},
        quality: :default,
        format: :png
      })

    assert_in_delta zoom_x, 0.5, 0.0001
    assert_in_delta zoom_y, 0.5, 0.0001
  end

  test "rotation 180 emits rotate op" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 180},
        quality: :default,
        format: :png
      })

    assert Enum.any?(ops, &match?(%Rotate{angle: 180}, &1))
  end

  test "quality color emits no gray op" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 0},
        quality: :color,
        format: :png
      })

    refute Enum.any?(ops, &match?(%Gray{}, &1))
  end

  test "format avif emits explicit avif output" do
    {:ok, %Plan{output: %{mode: {:explicit, :avif}}}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 0},
        quality: :default,
        format: :avif
      })
  end

  test "format webp emits explicit webp output" do
    {:ok, %Plan{output: %{mode: {:explicit, :webp}}}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 0},
        quality: :default,
        format: :webp
      })
  end

  test "auto_rotate option is propagated to plan" do
    {:ok, %Plan{auto_rotate: true}} =
      PlanBuilder.image_plan(
        @source,
        %{
          region: :full,
          size: {:max, false},
          rotation: {false, 0},
          quality: :default,
          format: :jpg
        },
        auto_rotate: true
      )

    {:ok, %Plan{auto_rotate: false}} =
      PlanBuilder.image_plan(
        @source,
        %{
          region: :full,
          size: {:max, false},
          rotation: {false, 0},
          quality: :default,
          format: :jpg
        },
        auto_rotate: false
      )
  end

  test "plan passes validate_shape" do
    {:ok, plan} =
      build(%{
        region: {:px, 0, 0, 100, 100},
        size: {:wh, 50, 50, true},
        rotation: {false, 90},
        quality: :gray,
        format: :webp
      })

    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "arbitrary angle emits a Rotate op with the angle" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {false, 45},
        quality: :default,
        format: :png
      })

    assert [%Resize{}, %Rotate{angle: 45, mirror: false}] = ops
  end

  test "mirror + angle emits a mirrored Rotate op" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {true, 90},
        quality: :default,
        format: :png
      })

    assert [%Resize{}, %Rotate{angle: 90, mirror: true}] = ops
  end

  test "mirror with zero angle emits a horizontal Flip (no Rotate)" do
    {:ok, %Plan{pipelines: [%{operations: ops}]}} =
      build(%{
        region: :full,
        size: {:max, false},
        rotation: {true, 0},
        quality: :default,
        format: :png
      })

    assert [%Resize{}, %Flip{axis: :horizontal}] = ops
  end
end

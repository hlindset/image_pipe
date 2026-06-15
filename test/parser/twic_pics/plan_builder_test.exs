defmodule ImagePipe.Parser.TwicPics.PlanBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  defp build(chain), do: PlanBuilder.to_plan(%Source.Path{segments: ["x.jpg"]}, chain)

  test "resize single dim -> fit auto; WxH -> stretch" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [r1]}]}} = build([{"resize", "100"}])
    assert %Operation.Resize{mode: :fit, width: {:px, 100}, height: :auto} = r1

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [r2]}]}} = build([{"resize", "100x50"}])
    assert %Operation.Resize{mode: :stretch, width: {:px, 100}, height: {:px, 50}} = r2
  end

  test "relative-unit resize is emitted as one op per segment (no static collapse)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [a, b]}]}} =
             build([{"resize", "340"}, {"resize", "50p"}])

    assert %Operation.Resize{width: {:px, 340}} = a
    assert %Operation.Resize{width: {:ratio, 1, 2}} = b
  end

  test "focus anchor steers the next cover" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [cover]}]}} =
             build([{"focus", "top"}, {"cover", "100x100"}])

    assert %Operation.Resize{mode: :cover, guide: {:anchor, :center, :top}} = cover
  end

  test "relative-unit coordinate focus -> focal ratio guide on the next cover" do
    # focus=25px75p splits on x -> ["25p","75p"] -> x=25% (1/4), y=75% (3/4).
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [cover]}]}} =
             build([{"focus", "25px75p"}, {"cover", "100x100"}])

    assert %Operation.Resize{
             mode: :cover,
             guide: {:focal, {:ratio, 1, 4}, {:ratio, 3, 4}}
           } = cover
  end

  test "an edge focal ratio of exactly 1 (100p) is in-range" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [cover]}]}} =
             build([{"focus", "100px0p"}, {"cover", "100x100"}])

    assert %Operation.Resize{guide: {:focal, {:ratio, 1, 1}, {:ratio, 0, 1}}} = cover
  end

  test "out-of-range, bare-pixel, and named focus values are rejected" do
    # focus=150px50p -> x ratio 3/2 (>100%) is out of the image.
    assert {:error, {:unsupported_focus, "150px50p"}} = build([{"focus", "150px50p"}])
    # focus=20x10 -> both bare px; deferred (needs running-dim resolution).
    assert {:error, {:unsupported_focus, "20x10"}} = build([{"focus", "20x10"}])
    assert {:error, _} = build([{"focus", "auto"}])
    assert {:error, _} = build([{"focus", "center"}])
  end

  test "cover ratio -> guided ratio crop" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [crop]}]}} = build([{"cover", "16:9"}])

    assert %Operation.CropGuided{
             width: :full_axis,
             height: :full_axis,
             aspect_ratio: {:ratio, 16, 9}
           } =
             crop
  end

  test "cover decimal ratio reduces and flows into the guided crop" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [crop]}]}} =
             build([{"cover", "1.5:2"}])

    assert %Operation.CropGuided{aspect_ratio: {:ratio, 3, 4}} = crop
  end

  test "inside -> fit resize plus transparent canvas" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [resize, canvas]}]}} =
             build([{"inside", "100x80"}])

    assert %Operation.Resize{mode: :fit} = resize
    assert %Operation.Canvas{fill: :transparent} = canvas
  end

  test "inside ratio -> single pad-to-ratio transparent canvas" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [canvas]}]}} =
             build([{"inside", "4:3"}])

    assert %Operation.Canvas{
             width: {:ratio, 4, 1},
             height: {:ratio, 3, 1},
             placement: :center,
             fill: :transparent
           } = canvas
  end

  test "crop without coords uses the guide; with coords resets to center and emits CropRegion" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [guided]}]}} =
             build([{"focus", "top"}, {"crop", "100x100"}])

    assert %Operation.CropGuided{guide: {:anchor, :center, :top}} = guided

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [region, after_crop]}]}} =
             build([{"crop", "100x100@20x50"}, {"cover", "10x10"}])

    assert %Operation.CropRegion{
             x: {:px, 20},
             y: {:px, 50},
             width: {:px, 100},
             height: {:px, 100}
           } = region

    assert %Operation.Resize{mode: :cover, guide: :center} = after_crop
  end

  test "output/quality last-wins, applied to Output not the pipeline" do
    assert {:ok, %Plan{output: %Output{mode: {:explicit, :webp}, quality: {:quality, 70}}}} =
             build([{"resize", "10"}, {"output", "avif"}, {"output", "webp"}, {"quality", "70"}])
  end

  test "rejected non-goals fail the whole build" do
    assert {:error, {:unsupported_transform, "zoom"}} = build([{"zoom", "2"}])
    assert {:error, _} = build([{"resize", "16:9"}])
    assert {:error, _} = build([{"focus", "auto"}])
    assert {:error, _} = build([{"focus", "center"}])
  end

  test "relative units on inside are rejected (pixel-only)" do
    assert {:error, {:unsupported_unit, :inside}} = build([{"inside", "50p"}])
  end

  test "relative crop dimensions and zero-based coordinates build a plan" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [guided]}]}} =
             build([{"crop", "50px50p"}])

    assert %Operation.CropGuided{width: {:ratio, 1, 2}, height: {:ratio, 1, 2}} = guided

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [region]}]}} =
             build([{"crop", "200x200@0.25sx0.5s"}])

    assert %Operation.CropRegion{
             x: {:ratio, 1, 4},
             y: {:ratio, 1, 2},
             width: {:px, 200},
             height: {:px, 200}
           } = region

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%Operation.CropRegion{x: {:px, 0}, y: {:px, 0}}]}
              ]
            }} =
             build([{"crop", "100x100@0x0"}])
  end

  test "a region crop requires both axes explicit (omitted axis is rejected)" do
    assert {:error, {:unsupported_crop_region_size, "100"}} =
             build([{"crop", "100@20x50"}])
  end

  test "an empty pipeline still produces a valid no-op plan when only output is set" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} = build([{"output", "auto"}])
  end
end

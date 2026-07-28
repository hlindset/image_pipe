defmodule ImagePipe.Parser.IIIF.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.IIIF.{Info, InfoRenderer}
  alias ImagePipe.Plan.{RenderContext, SourceInfo}

  @info %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 1}
  @params %{
    id: "http://x/iiif/abc",
    level: "level2",
    offers: [],
    formats: [:jpg, :png],
    qualities: [:default, :color, :gray, :bitonal],
    tile_size: 512,
    max_width: nil,
    max_height: nil,
    max_area: nil
  }

  test "document has required IIIF 3.0 fields with display dims" do
    doc = Info.document(@info, @params)
    assert doc["@context"] == "http://iiif.io/api/image/3/context.json"
    assert doc["id"] == "http://x/iiif/abc"
    assert doc["type"] == "ImageService3"
    assert doc["protocol"] == "http://iiif.io/api/image"
    assert doc["profile"] == "level2"
    assert doc["width"] == 1000 and doc["height"] == 600
  end

  test "extra* lists exclude baseline (default quality; jpg/png formats)" do
    doc = Info.document(@info, %{@params | formats: [:jpg, :png, :webp, :avif]})
    # extraQualities lists qualities beyond `default`
    assert doc["extraQualities"] == ["color", "gray", "bitonal"]
    # extraFormats lists formats beyond the Level-2 baseline jpg/png
    assert doc["extraFormats"] == ["webp", "avif"]
  end

  test "extraFeatures advertises rotationArbitrary and mirroring" do
    doc = Info.document(@info, @params)
    assert "rotationArbitrary" in doc["extraFeatures"]
    assert "mirroring" in doc["extraFeatures"]
  end

  test "quarter-turn orientation swaps width/height in info" do
    doc =
      Info.document(
        %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 6},
        @params
      )

    assert doc["width"] == 600 and doc["height"] == 1000
  end

  test "document emits tiles and sizes computed from display dims" do
    # 1000x600 source: short side 600 -> 300,150,75,37.5<64 at i=3 -> [1,2,4,8]
    doc = Info.document(@info, @params)

    assert doc["tiles"] == [%{"width" => 512, "height" => 512, "scaleFactors" => [1, 2, 4, 8]}]

    assert doc["sizes"] == [
             %{"width" => 125, "height" => 75},
             %{"width" => 250, "height" => 150},
             %{"width" => 500, "height" => 300},
             %{"width" => 1000, "height" => 600}
           ]
  end

  test "tiles/sizes use display (orientation-swapped) dims for EXIF 5-8" do
    doc =
      Info.document(
        %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 6},
        @params
      )

    # display dims are 600x1000 -> short side 600 -> [1,2,4,8]; tile clamps height to 512
    assert doc["width"] == 600 and doc["height"] == 1000
    assert doc["tiles"] == [%{"width" => 512, "height" => 512, "scaleFactors" => [1, 2, 4, 8]}]
    assert List.last(doc["sizes"]) == %{"width" => 600, "height" => 1000}
  end

  test "renderer returns application/json body" do
    {:ok, {"application/json", body}} =
      InfoRenderer.render(%RenderContext{info: @info}, @params, [])

    assert IO.iodata_to_binary(body) =~ "ImageService3"
  end

  describe "max bounds advertising" do
    test "emits maxWidth/maxHeight/maxArea when configured" do
      doc =
        Info.document(@info, %{@params | max_width: 2000, max_height: 1500, max_area: 3_000_000})

      assert doc["maxWidth"] == 2000
      assert doc["maxHeight"] == 1500
      assert doc["maxArea"] == 3_000_000
    end

    test "omits unset bounds (only maxWidth configured)" do
      doc = Info.document(@info, %{@params | max_width: 2000})
      assert doc["maxWidth"] == 2000
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end

    test "omits all when none configured (the @params default)" do
      doc = Info.document(@info, @params)
      refute Map.has_key?(doc, "maxWidth")
      refute Map.has_key?(doc, "maxHeight")
      refute Map.has_key?(doc, "maxArea")
    end
  end
end

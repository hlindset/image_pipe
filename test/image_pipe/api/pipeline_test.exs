defmodule ImagePipe.API.PipelineTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp parse!(segments) do
    source = "test"

    lexed = %{
      segments: Enum.map(segments, &seg/1),
      source: {:src, source, {0, byte_size(source)}}
    }

    assert {:ok, request} = Parser.parse(lexed, [])
    request
  end

  defp state_for(width, height) do
    {:ok, image} = Image.new(width, height, color: [255, 255, 255])
    %State{image: image}
  end

  describe "operation_names/1" do
    test "reports effects in fixed stage order" do
      request =
        parse!([
          "dpr=2",
          "gradient=1,red,left,0.25,0.75",
          "colorize=1,ff0000,keep-alpha",
          "saturation=0.5",
          "contrast=1.25",
          "brightness=-20",
          "duotone=1,112233,ffeecc",
          "monochrome=1,red",
          "bitonal",
          "gray",
          "pixelate=8",
          "sharpen=1.5",
          "blur=2"
        ])

      assert Executor.operation_names(request) == [
               :blur,
               :sharpen,
               :pixelate,
               :gray,
               :bitonal,
               :monochrome,
               :duotone,
               :brightness,
               :contrast,
               :saturation,
               :colorize,
               :gradient
             ]
    end

    test "reports geometry and presentation stages in execution order" do
      request =
        parse!([
          "trim=auto",
          "region=100,100,800,600",
          "w=400",
          "h=400",
          "blur=3",
          "extend",
          "pad=10",
          "bg=ff0000"
        ])

      assert Executor.operation_names(request) == [
               :trim,
               :crop_region,
               :resize,
               :blur,
               :canvas,
               :padding,
               :background
             ]
    end
  end

  describe "execute/3" do
    test "anchor=smart executes without a configured detector" do
      state = state_for(400, 400)
      assert state.detector == nil

      request = parse!(["crop=200,200", "anchor=smart"])

      assert {:ok, %State{image: image}} = Executor.execute(state, request, [])
      assert {Image.width(image), Image.height(image)} == {200, 200}
    end
  end

  describe "decode_request/2" do
    defp preflight_geometry(dims) do
      %SourceGeometry{
        storage_dimensions: dims,
        display_dimensions: dims,
        pending_orientation: %PendingOrientation{},
        source_format: :png
      }
    end

    defp preflight_shrink(segments, dims, format) do
      request = parse!(segments)

      DecodePlanner.open_options_for(
        Executor.decode_request(request, preflight_geometry(dims)),
        format,
        dims
      )
    end

    test "a single-axis resize targets that axis alone" do
      request = parse!(["w=400"])

      assert Executor.decode_request(request, preflight_geometry({3200, 2405})).resize_target ==
               {400, nil}

      assert preflight_shrink(["w=400"], {3200, 2405}, :jpeg)[:shrink] == 8

      assert_in_delta preflight_shrink(["w=400"], {3200, 2405}, :webp)[:scale],
                      0.125,
                      1.0e-12

      refute Keyword.has_key?(preflight_shrink(["w=400"], {3200, 2405}, :png), :shrink)
    end

    test "a two-axis resize preserves both concrete targets" do
      request = parse!(["w=250", "h=190"])

      assert Executor.decode_request(request, preflight_geometry({2401, 3199})).resize_target ==
               {250, 190}

      assert preflight_shrink(["w=250", "h=190"], {2401, 3199}, :jpeg)[:shrink] == 8
    end
  end
end

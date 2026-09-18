defmodule ImagePipe.Native.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Info
  alias ImagePipe.Native.Parser
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  test "renders canonical source format names, display dimensions, and optional size" do
    info = %SourceInfo{
      format: :jpeg_xl,
      width: 40,
      height: 80,
      orientation: 6,
      byte_size: 12_345
    }

    assert {"application/json", body} = Info.render(info)

    assert body |> IO.iodata_to_binary() |> JSON.decode!() == %{
             "format" => "jpeg_xl",
             "mime_type" => "image/jxl",
             "width" => 80,
             "height" => 40,
             "orientation" => 6,
             "size" => 12_345
           }
  end

  test "omits unavailable source size" do
    info = %SourceInfo{format: :heif, width: 10, height: 20, orientation: 1}

    assert {"application/json", body} = Info.render(info)

    refute body |> IO.iodata_to_binary() |> JSON.decode!() |> Map.has_key?("size")
  end

  test "reads source facts without applying transforms or encoding" do
    config = Config.validate!(sources: @sources)
    source = %Path{segments: ["images", "beach.jpg"]}
    assert {:ok, resolved} = Source.resolve(source, config, config)
    source_value = "images/beach.jpg"

    assert {:ok, %Request{} = request} =
             Parser.parse(
               %{
                 segments: [{"output=info", {0, 11}}],
                 source: {:src, source_value, {12, byte_size(source_value)}}
               },
               config
             )

    assert {:ok, "application/json", body} = Info.render_source(resolved, request, config)

    assert %{
             "format" => "jpeg",
             "mime_type" => "image/jpeg",
             "width" => 4000,
             "height" => 2667,
             "orientation" => 1,
             "size" => size
           } = body |> IO.iodata_to_binary() |> JSON.decode!()

    assert is_integer(size) and size > 0
  end
end

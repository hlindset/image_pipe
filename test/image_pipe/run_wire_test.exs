defmodule ImagePipe.RunWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe, as: IP
  alias Vix.Vips.Image, as: VipsImage

  @root "test/support/image_pipe/test/sources"
  @source_config [sources: [path: {ImagePipe.Source.File, root: @root, root_id: "fixtures"}]]

  test "binary, file, configured source and HTTP share oriented grouped pixels" do
    plan =
      IP.new()
      |> IP.group(resize: [width: 40, height: 30, fit: :cover], anchor: :top_left, dpr: 2)
      |> IP.group(region: {5, 3, 20, 15}, brightness: 20, padding: 2, background: "white")
      |> IP.output(format: :png, color_profile: {:convert, :srgb})

    path =
      "w=40/h=30/fit=cover/anchor=top-left/dpr=2/then/region=5,3,20,15/brightness=20/pad=2/bg=white/format=png/profile=srgb"

    config = IP.Plug.init(@source_config)

    for name <- ["exif_6.jpg", "alpha.png"] do
      input = Path.join(@root, name)
      response = conn(:get, "/#{path}/src/#{name}") |> IP.Plug.call(config)
      assert response.status == 200
      expected = Image.from_binary!(response.resp_body)

      for source <- [{:binary, File.read!(input)}, {:file, input}, {:source, name}] do
        assert {:ok, result} = IP.run(plan, source, @source_config)
        actual = Image.from_binary!(result.data)
        assert {result.width, result.height} == {24, 19}
        assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
      end
    end
  end

  test "orientation policy and effects work without geometry through both entry points" do
    config = IP.Plug.init(@source_config)
    source = {:file, Path.join(@root, "exif_6.jpg")}

    for orient <- [:auto, :none] do
      plan = IP.new(orient: orient) |> IP.group(brightness: 40) |> IP.output(format: :png)
      assert {:ok, actual} = IP.run(plan, source)
      assert {:ok, baseline} = IP.run(IP.new(orient: orient) |> IP.output(format: :png), source)

      response =
        conn(:get, "/orient=#{orient}/brightness=40/format=png/src/exif_6.jpg")
        |> IP.Plug.call(config)

      assert response.status == 200
      assert pixels(actual.data) == pixels(response.resp_body)
      refute pixels(actual.data) == pixels(baseline.data)
    end
  end

  test "info and placeholder terminal values match HTTP" do
    config = IP.Plug.init(@source_config)

    for {terminal, token} <- [info: "info", blurhash: "blurhash", lqip_css: "lqip-css"] do
      plan = IP.new() |> IP.output(terminal: terminal)
      assert {:ok, result} = IP.run(plan, {:source, "exif_6.jpg"}, @source_config)
      response = conn(:get, "/output=#{token}/src/exif_6.jpg") |> IP.Plug.call(config)
      assert response.status == 200

      expected =
        if terminal == :info, do: JSON.decode!(response.resp_body), else: response.resp_body

      assert result.data == expected
    end
  end

  test "matching host defaults, negotiation and result limits produce matching output" do
    options = @source_config ++ [quality: 65, max_result_width: 30, max_result_height: 30]
    config = IP.Plug.init(options)
    plan = IP.new() |> IP.group(resize: [width: 200])

    assert {:ok, result} =
             IP.run(plan, {:source, "small.png"}, Keyword.put(options, :accept, "image/webp"))

    response =
      conn(:get, "/w=200/src/small.png")
      |> put_req_header("accept", "image/webp")
      |> IP.Plug.call(config)

    assert response.status == 200
    assert result.format == :webp
    assert result.width <= 30 and result.height <= 30
    assert pixels(result.data) == pixels(response.resp_body)
  end

  defp pixels(bytes), do: bytes |> Image.from_binary!() |> VipsImage.write_to_binary()
end

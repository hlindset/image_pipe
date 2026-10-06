defmodule ImagePipe.API.InfoWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage

  @prefix [:api_info_wire]

  setup do
    body =
      24
      |> Image.new!(16, color: :red)
      |> Image.set_orientation!(6)
      |> Image.write!(:memory, suffix: ".jpg")

    %{body: body}
  end

  test "info reports source metadata in the display frame without negotiating Accept", %{
    body: body
  } do
    config = mount(body)
    response = request("output=info", config, "image/avif")

    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(response, "vary") == []

    assert JSON.decode!(response.resp_body) == %{
             "source" => %{
               "format" => "jpeg",
               "mime_type" => "image/jpeg",
               "width" => 16,
               "height" => 24,
               "orientation" => 6,
               "pages" => 1,
               "size" => byte_size(body)
             },
             "result" => %{"width" => 16, "height" => 24, "dpr" => 1.0}
           }
  end

  test "result follows the request's orientation while source keeps the EXIF display frame", %{
    body: body
  } do
    info = info("orient=none/output=info", mount(body))
    assert {info["source"]["width"], info["source"]["height"]} == {16, 24}
    assert info["result"] == %{"width" => 24, "height" => 16, "dpr" => 1.0}
  end

  test "result dimensions match the image the same URL serves" do
    body = gradient_jpeg(120, 80)
    config = mount(body)

    for options <- [
          "w=50",
          "w=40/h=40/fit=cover/rotate=90",
          "crop=60,30/pad=5",
          "w=30/-/extend/w=40/h=40",
          "orient=none/w=33"
        ] do
      image = request(options, config)
      assert image.status == 200, options
      decoded = Image.from_binary!(image.resp_body)
      result = info(options <> "/output=info", config)["result"]

      assert {result["width"], result["height"]} == {Image.width(decoded), Image.height(decoded)},
             options
    end
  end

  test "result dpr is the last group's effective DPR" do
    config = mount(gradient_jpeg(120, 80))

    assert %{"width" => 100, "dpr" => 2.0} = info("w=50/dpr=2/output=info", config)["result"]
    # Without enlargement the 120px source clamps a 200px target to DPR 1.2.
    assert %{"width" => 120, "dpr" => 1.2} = info("w=100/dpr=2/output=info", config)["result"]

    assert %{"width" => 104, "dpr" => 1.0} =
             info("w=50/dpr=2/-/pad=2/output=info", config)["result"]

    assert %{"width" => 108, "dpr" => 2.0} =
             info("w=50/dpr=2/-/pad=2/dpr=2/output=info", config)["result"]
  end

  test "requested placeholders equal the standalone outputs with one source fetch" do
    # A photo, so a placeholder from a smaller decode differs from a full-size one.
    config = mount(File.read!("priv/static/images/beach.jpg"))

    for options <- ["", "w=60/", "crop=200,100/blur=2/", "pad=20/"] do
      blurhash = request(options <> "output=blurhash", config).resp_body
      lqip = request(options <> "output=lqip-css", config).resp_body
      assert_received :origin_fetch
      assert_received :origin_fetch

      response = request(options <> "output=info,lqip-css,blurhash", config)
      assert response.status == 200, options
      assert_received :origin_fetch
      refute_received :origin_fetch

      result = JSON.decode!(response.resp_body)["result"]
      assert result["blurhash"] == blurhash, options
      assert result["lqip_css"] == lqip, options
    end

    result = info("w=60/output=info,lqip-css", config)["result"]
    assert Map.has_key?(result, "lqip_css")
    refute Map.has_key?(result, "blurhash")
  end

  test "groups, orientation, and placeholders separate info cache entries", %{body: body} do
    config = mount(body)

    etags =
      for options <- [
            "output=info",
            "w=8/output=info",
            "orient=none/output=info",
            "output=info,blurhash",
            "output=info,lqip-css"
          ] do
        get_resp_header(request(options, config), "etag")
      end

    assert length(Enum.uniq(etags)) == length(etags)
    assert get_resp_header(request("q=80/output=info", config), "etag") == hd(etags)
  end

  test "info reports display dimensions for every EXIF orientation" do
    for orientation <- 1..8 do
      body =
        24
        |> Image.new!(16, color: :red)
        |> Image.set_orientation!(orientation)
        |> Image.write!(:memory, suffix: ".jpg")

      response = request("output=info", mount(body))
      assert response.status == 200
      info = JSON.decode!(response.resp_body)["source"]
      expected_dimensions = if orientation in 5..8, do: {16, 24}, else: {24, 16}

      assert {info["width"], info["height"]} == expected_dimensions
      assert info["orientation"] == orientation
    end
  end

  test "info uses canonical JPEG XL format and MIME names" do
    image = Image.new!(24, 16, color: :red)
    assert {:ok, body} = VipsImage.write_to_buffer(image, ".jxl")
    response = request("output=info", mount(body, [], "image/jxl"))

    assert response.status == 200

    assert JSON.decode!(response.resp_body)["source"] == %{
             "format" => "jpeg_xl",
             "mime_type" => "image/jxl",
             "width" => 24,
             "height" => 16,
             "orientation" => 1,
             "pages" => 1,
             "size" => byte_size(body)
           }
  end

  test "JPEG XL sources transcode to supported output formats" do
    image = Image.new!(24, 16, color: :red)
    assert {:ok, body} = VipsImage.write_to_buffer(image, ".jxl")
    config = mount(body, [], "image/jxl")

    for {options, accept, mime} <- [
          {"w=12", "image/jxl", "image/jpeg"},
          {"w=12", "image/jxl,image/webp", "image/webp"},
          {"w=12/format=png", "image/jxl", "image/png"}
        ] do
      response = request(options, config, accept)
      assert response.status == 200
      assert [content_type] = get_resp_header(response, "content-type")
      assert String.starts_with?(content_type, mime)
      decoded = Image.from_binary!(response.resp_body)
      assert {Image.width(decoded), Image.height(decoded)} == {12, 8}
    end
  end

  test "info computation has a terminal span without pixel processing", %{body: body} do
    events = [
      [:output, :terminal, :stop],
      [:transform, :execute, :start],
      [:transform, :materialize, :start],
      [:output, :encode, :start]
    ]

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        Enum.map(events, &(@prefix ++ &1)),
        fn event, _measurements, metadata, pid -> send(pid, {:stage, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert request("output=info", mount(body, telemetry_prefix: @prefix)).status == 200

    assert_received {:stage, @prefix ++ [:output, :terminal, :stop],
                     %{terminal: :info, placeholders: [], result: :ok}}

    refute_received {:stage, @prefix ++ [:transform, :execute, :start], _}
    refute_received {:stage, @prefix ++ [:transform, :materialize, :start], _}
    refute_received {:stage, @prefix ++ [:output, :encode, :start], _}
  end

  test "preset transforms apply to the result", %{body: body} do
    config = mount(body, presets: %{"card" => "w=10"})
    assert %{"width" => 10} = info("preset=card/output=info", config)["result"]
  end

  test "image-only URL options do not change info", %{body: body} do
    plain = request("output=info", mount(body))

    for option <- ["format=jpeg", "q=80", "meta=keep", "profile=strip", "hdr=preserve"] do
      ignored = request("output=info/#{option}", mount(body))
      assert ignored.status == 200, option
      assert ignored.resp_body == plain.resp_body
      assert get_resp_header(ignored, "etag") == get_resp_header(plain, "etag")
    end
  end

  test "image options an image request rejects fail non-image outputs before fetch", %{
    body: body
  } do
    config = mount(body)

    for output <- ["image", "info", "blurhash", "lqip-css"] do
      response = request("output=#{output}/profile=srgb/hdr=preserve", config)
      assert response.status == 400, output
      refute_received :origin_fetch
    end
  end

  test "host image encoding policies do not change info", %{body: body} do
    plain = request("output=info", mount(body))

    configured =
      request(
        "output=info",
        mount(body, strip_metadata: false, strip_color_profile: false, preserve_hdr: true)
      )

    assert configured.status == 200
    assert configured.resp_body == plain.resp_body
    assert get_resp_header(configured, "etag") == get_resp_header(plain, "etag")
  end

  test "info reuses its complete body across Accept values and strong conditionals", %{body: body} do
    store = :ets.new(:api_info_cache, [:set, :public])
    config = mount(body, cache: {CacheProbe, store: store}, http_cache: :auto)
    first = request("output=info", config, "image/webp")
    assert first.status == 200
    assert_received :origin_fetch
    assert [key] = Enum.uniq(CacheProbe.lookup_keys())
    assert_received {:cache_put, ^key, _}
    [etag] = get_resp_header(first, "etag")

    second = request("output=info", config, "image/avif")
    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "etag") == [etag]
    assert [^key] = Enum.uniq(CacheProbe.lookup_keys())
    refute_received :origin_fetch
    refute_received {:cache_put, _, _}

    conditional =
      conn(:head, "/output=info/src/source.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(config)

    assert conditional.status == 304
    assert conditional.resp_body == ""
    refute_received :origin_fetch
    refute_received {:cache_lookup, _}
  end

  test "source safety limits and decode errors also apply to info", %{body: body} do
    assert request("output=info", mount(body, max_input_pixels: 100)).status == 413
    assert request("output=info", mount(body, max_body_bytes: 10)).status == 413
    corrupt = "not an image \xFF\xFE\x00"
    assert request("output=info", mount(corrupt)).status == 415
  end

  test "cache read failures leave source info available", %{body: body} do
    config = mount(body, cache: {CacheProbe, result: {:error, :unavailable}})
    response = request("output=info", config)

    assert response.status == 200
    assert %{"source" => %{"width" => 16, "height" => 24}} = JSON.decode!(response.resp_body)
    assert_received {:cache_lookup, _}
    assert_received :origin_fetch
  end

  test "expiry uses the host clock and rejects before side effects", %{body: body} do
    config = mount(body, clock: fn -> 100 end, cache: {CacheProbe, []})
    assert request("output=info/expires=99", config).status == 410
    refute_received :origin_fetch
    refute_received {:cache_lookup, _}
    assert request("output=info/expires=100", config).status == 200
    assert_received :origin_fetch
  end

  defp info(options, config) do
    response = request(options, config)
    assert response.status == 200, options
    JSON.decode!(response.resp_body)
  end

  defp gradient_jpeg(width, height) do
    width
    |> Image.linear_gradient!(height, start_color: :navy, finish_color: :orange)
    |> Image.write!(:memory, suffix: ".jpg")
  end

  defp request(options, config, accept \\ "*/*") do
    conn(:get, "/#{options}/src/source.jpg")
    |> put_req_header("accept", accept)
    |> ImagePipe.Plug.call(config)
  end

  defp mount(body, extra \\ [], content_type \\ "image/jpeg") do
    pid = self()

    origin = fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type(content_type) |> send_resp(200, body)
    end

    [
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            byte_identity: :strong,
            internal_cache: :enabled,
            req_options: [plug: origin]
          ]
        ]
      ]
    ]
    |> Keyword.merge(extra)
    |> ImagePipe.Plug.init()
  end
end

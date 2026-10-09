defmodule ImagePipe.API.LqipCssWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Image.Lqip.Css
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver
  alias Vix.Vips.Operation

  setup do
    image =
      Image.new!(90, 60, color: :red)
      |> Image.Draw.rect!(30, 0, 30, 60, color: :lime)
      |> Image.Draw.rect!(60, 0, 30, 60, color: :blue)

    %{image: image, body: Image.write!(image, :memory, suffix: ".png")}
  end

  test "returns Image's packed CSS value with a fixed text response", %{image: image, body: body} do
    response = request("output=lqip-css", mount(body), "image/avif")

    assert response.status == 200
    assert response.resp_body == Css.encode!(image)
    assert response.resp_body =~ ~r/^#[0-9a-f]{8}$/
    assert get_resp_header(response, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(response, "vary") == []
  end

  test "a large JPEG decoded smaller gives the full-size value" do
    body =
      Image.new!(1600, 1200, color: :red)
      |> Image.Draw.rect!(533, 0, 534, 1200, color: :lime)
      |> Image.Draw.rect!(1067, 0, 533, 1200, color: :blue)
      |> Image.write!(:memory, suffix: ".jpg")

    response = request("output=lqip-css", mount(body, [], "image/jpeg"))

    assert response.resp_body == Css.encode!(Image.from_binary!(body))
  end

  # JPEG shrinks on load and PNG doesn't. Padding is sized in pixels, so a
  # placeholder decoded smaller would pad a larger share of the frame.
  describe "pad before a placeholder matches the full-size decode" do
    setup do
      image =
        Image.new!(1600, 1200, color: :red)
        |> Image.Draw.rect!(533, 0, 534, 1200, color: :lime)
        |> Image.Draw.rect!(1067, 0, 533, 1200, color: :blue)

      placeholders = fn output ->
        for {suffix, type} <- [{".jpg", "image/jpeg"}, {".png", "image/png"}] do
          body = Image.write!(image, :memory, suffix: suffix)
          request("pad=200/output=#{output}", mount(body, [], type)).resp_body
        end
      end

      %{placeholders: placeholders}
    end

    test "for lqip-css", %{placeholders: placeholders} do
      [jpeg, png] = placeholders.("lqip-css")
      assert jpeg == png
    end

    # JPEG compression moves the hash's last digits, so compare the colours it decodes to.
    test "for blurhash", %{placeholders: placeholders} do
      [jpeg, png] = placeholders.("blurhash")
      assert blurhash_difference(jpeg, png) < 3
    end
  end

  defp blurhash_difference(a, b) do
    {:ok, a} = Image.Blurhash.decode(a, 32, 24)
    {:ok, b} = Image.Blurhash.decode(b, 32, 24)
    {:ok, difference} = Operation.subtract(a, b)
    {:ok, difference} = Operation.abs(difference)
    {:ok, mean} = Operation.avg(difference)
    mean
  end

  test "effects without geometry and grouped transforms reach the placeholder", %{body: body} do
    config = mount(body)
    plain = request("output=lqip-css", config)
    gray = request("gray/output=lqip-css", config)
    cropped = request("w=45/-/region=30,0,15,30/output=lqip-css", config)

    assert gray.status == 200
    assert gray.resp_body != plain.resp_body
    assert cropped.status == 200
    assert cropped.resp_body == Css.encode!(Image.new!(15, 30, color: :blue))

    image_response = request("gray/format=png", config)
    reference = Image.from_binary!(image_response.resp_body)
    assert gray.resp_body == Css.encode!(reference)
  end

  test "EXIF orientation and explicit rotation use displayed pixels", %{image: image} do
    image = Image.Draw.rect!(image, 0, 30, 30, 30, color: :yellow)
    body = image |> Image.set_orientation!(6) |> Image.write!(:memory, suffix: ".png")
    config = mount(body)
    oriented = request("output=lqip-css", config)
    stored = request("orient=none/output=lqip-css", config)
    rotated = request("orient=none/rotate=90/output=lqip-css", config)

    assert oriented.status == 200
    assert stored.status == 200
    assert rotated.status == 200
    assert oriented.resp_body == rotated.resp_body
    assert oriented.resp_body != stored.resp_body
  end

  # PNG has no shrink-on-load, so the placeholder reads the full-size frame.
  test "streamed photographic input matches Image's encoder" do
    body =
      "priv/static/images/beach.jpg"
      |> Image.thumbnail!(1200)
      |> Image.write!(:memory, suffix: ".png")

    response = request("output=lqip-css", mount(body))
    reference = Image.from_binary!(body)

    assert response.status == 200
    assert response.resp_body == Css.encode!(reference)
  end

  test "transparent pixels are flattened on black and tiny sources can be encoded" do
    for {width, height} <- [{1, 1}, {1, 30}, {40, 1}, {15, 20}] do
      image = Image.new!(width, height, color: [255, 0, 0, 0], bands: 4)
      body = Image.write!(image, :memory, suffix: ".png")
      response = request("output=lqip-css", mount(body))

      assert response.status == 200
      assert response.resp_body == "#00000000"
    end
  end

  test "wide-gamut and high-bit-depth sources use the same sRGB pixels as image output" do
    for filename <- ["icc_p3.png", "rgb16.png", "rgba16.png"] do
      body = File.read!(Path.join("test/support/image_pipe/test/sources", filename))
      config = mount(body)
      response = request("output=lqip-css", config)
      # The placeholder samples a 3×3 reduction, so compare it with image output
      # reduced the same way.
      reference =
        request("w=3/h=3/fit=stretch/format=png/profile=strip/hdr=tonemap/bg=black", config)

      assert reference.status == 200
      assert response.status == 200

      expected = reference.resp_body |> Image.from_binary!() |> Css.encode!()
      assert response.resp_body == expected, filename
    end
  end

  test "terminal telemetry reports success and materializes only the sampling frame", %{
    body: body
  } do
    prefix = [:lqip_css_wire]
    handler = {__MODULE__, make_ref()}

    events =
      Enum.map([[:output, :terminal, :stop], [:transform, :materialize, :stop]], &(prefix ++ &1))

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, pid -> send(pid, {:stage, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert request("output=lqip-css", mount(body, telemetry_prefix: prefix)).status == 200

    assert_received {:stage, [:lqip_css_wire, :output, :terminal, :stop],
                     %{terminal: :lqip_css, result: :ok}}

    assert_received {:stage, [:lqip_css_wire, :transform, :materialize, :stop],
                     %{dims: {3, 3}, result: :ok}}
  end

  test "image-only options are ignored, including preset-supplied ones", %{body: body} do
    config = mount(body, presets: %{"encoded" => "q=70"})
    plain = request("output=lqip-css", config)

    for option <- [
          "format=png",
          "q=70",
          "meta=keep",
          "profile=srgb",
          "hdr=preserve",
          "format-q=webp:60",
          "autoquality=false",
          "max-bytes=1000",
          "jpeg-options=progressive",
          "preset=encoded"
        ] do
      ignored = request("output=lqip-css/#{option}", config)
      assert ignored.status == 200, option
      assert ignored.resp_body == plain.resp_body
      assert get_resp_header(ignored, "etag") == get_resp_header(plain, "etag")
    end
  end

  test "cache reuse ignores Accept and option order, with conditional requests before access", %{
    body: body
  } do
    config = mount(body, CacheObserver.observe(http_cache: :auto))
    first = request("gray/output=lqip-css", config, "image/webp")
    assert first.status == 200
    assert_received :origin_fetch
    assert [key] = Enum.uniq(CacheObserver.lookup_hashes())
    assert_received {:cache_put, ^key, _}
    [etag] = get_resp_header(first, "etag")

    second = request("output=lqip-css/gray/filename=placeholder/attachment", config, "image/avif")
    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "etag") == [etag]
    assert [disposition] = get_resp_header(second, "content-disposition")
    assert disposition =~ "attachment"
    assert disposition =~ "placeholder.txt"
    assert [^key] = Enum.uniq(CacheObserver.lookup_hashes())
    refute_received :origin_fetch

    conditional =
      conn(:get, "/gray/output=lqip-css/src/source.png")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(config)

    assert conditional.status == 304
    assert conditional.resp_body == ""
    refute_received :origin_fetch
    refute_received {:cache_lookup, _, _}

    for options <- ["output=lqip-css", "gray/output=blurhash", "gray/format=png"] do
      response = request(options, config)
      assert response.status == 200
      refute get_resp_header(response, "etag") == [etag]
      assert [other_key] = Enum.uniq(CacheObserver.lookup_hashes())
      refute other_key == key
    end
  end

  test "host encoding policies do not affect the placeholder or its identity", %{body: body} do
    plain = request("output=lqip-css", mount(body))

    configured =
      request(
        "output=lqip-css",
        mount(body,
          strip_metadata: false,
          strip_color_profile: false,
          preserve_hdr: true,
          quality: 10
        )
      )

    assert configured.status == 200
    assert configured.resp_body == plain.resp_body
    assert get_resp_header(configured, "etag") == get_resp_header(plain, "etag")
  end

  test "source limits and decode failures remain enforced", %{body: body} do
    assert request("output=lqip-css", mount(body, max_input_pixels: 100)).status == 413
    assert request("output=lqip-css", mount(body, max_body_bytes: 10)).status == 413
    assert request("output=lqip-css", mount("invalid image")).status == 415
  end

  defp request(options, config, accept \\ "*/*") do
    conn(:get, "/#{options}/src/source.png")
    |> put_req_header("accept", accept)
    |> ImagePipe.Plug.call(config)
  end

  defp mount(body, extra \\ [], content_type \\ "image/png") do
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

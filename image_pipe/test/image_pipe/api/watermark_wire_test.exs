defmodule ImagePipe.API.WatermarkWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation, as: VipsOperation

  @blue [0, 0, 255]
  @red [255, 0, 0]
  @green [0, 255, 0]
  @source_key String.duplicate("2a", 32)
  @signing_key Base.encode16(:binary.copy(<<31>>, 32))

  setup do
    files = %{
      "image.png" => png(Image.new!(60, 40, color: @blue)),
      "mark.png" => png(Image.new!(10, 10, color: @red)),
      "alpha.png" => png(Image.new!(10, 10, color: @red ++ [128])),
      "pattern.png" => png(pattern_mark()),
      "gray_mark.png" => png(gray_mark()),
      "mid_mark.png" => png(Image.new!(10, 10, color: [1, 128, 200])),
      "tagged_gray.png" => png(tagged_gray()),
      "rotated.jpg" => rotated_jpeg(),
      "corrupt.png" => "not an image",
      "deep.png" => deep_png()
    }

    origin = origin(files)
    %{origin: origin, config: mount(origin)}
  end

  describe "placement" do
    test "a named watermark composites at the center by default", %{config: config} do
      plain = image("", config)
      marked = image("wm=logo", config)

      assert dimensions(marked) == {60, 40}
      assert pixel(marked, 26, 16) == @red
      assert pixel(marked, 35, 25) == @red
      assert pixel(marked, 25, 16) == @blue
      assert pixel(marked, 36, 25) == @blue
      assert VipsImage.bands(marked) == VipsImage.bands(plain)
    end

    test "anchors and signed offsets address the displayed frame", %{config: config} do
      for {options, inside, outside} <- [
            {"wm-at=top-left/wm-offset=2,3", {2, 3}, {1, 3}},
            {"wm-at=bottom-right/wm-offset=2,3", {57, 36}, {58, 36}},
            {"wm-at=top-left/wm-offset=10pct,25pct", {6, 10}, {5, 10}},
            {"wm-at=top-left/wm-offset=-5,-5", {4, 4}, {5, 5}}
          ] do
        marked = image("wm=logo/" <> options, config)
        assert pixel(marked, inside) == @red, options
        assert pixel(marked, outside) == @blue, options
      end
    end

    test "an asset entirely outside the frame leaves the image unchanged", %{config: config} do
      assert pixels(image("wm=logo/wm-at=top-left/wm-offset=100,0", config)) ==
               pixels(image("", config))
    end

    test "natural size and pixel offsets follow the effective DPR", %{config: config} do
      marked = image("wm=logo/wm-at=top-left/wm-offset=1,0/dpr=2", config)
      assert pixel(marked, 2, 19) == @red
      assert pixel(marked, 21, 19) == @red
      assert pixel(marked, 1, 0) == @blue
      assert pixel(marked, 22, 0) == @blue
    end

    test "scale fits the asset in a fraction of the frame", %{config: config} do
      marked = image("wm=logo/wm-scale=0.5", config)
      assert pixel(marked, 20, 10) == @red
      assert pixel(marked, 39, 29) == @red
      assert pixel(marked, 19, 10) == @blue
      assert pixel(marked, 40, 29) == @blue
    end

    test "tiles repeat from the anchored tile with gaps", %{config: config} do
      marked = image("wm=logo/wm-at=top-left/wm-tile/wm-gap=10,10", config)

      for {x, y} <- [{0, 0}, {20, 0}, {40, 0}, {9, 29}, {45, 25}],
          do: assert(pixel(marked, x, y) == @red, inspect({x, y}))

      for {x, y} <- [{10, 0}, {30, 15}, {50, 25}],
          do: assert(pixel(marked, x, y) == @blue, inspect({x, y}))
    end

    test "option order does not change the response", %{config: config} do
      options = ["wm=logo", "wm-at=bottom", "wm-offset=1,2", "wm-opacity=0.5", "w=50"]
      forward = response(Enum.join(options, "/"), config)
      reverse = response(options |> Enum.reverse() |> Enum.join("/"), config)
      assert forward.status == 200
      assert forward.resp_body == reverse.resp_body
      assert etag(forward) == etag(reverse)
    end

    test "the watermark runs after padding and background", %{config: config} do
      marked = image("pad=10/bg=ffffff/wm=logo/wm-at=bottom-right", config)
      assert dimensions(marked) == {80, 60}
      assert pixel(marked, 79, 59) == @red
      assert pixel(marked, 69, 59) == [255, 255, 255]
    end

    test "a later group receives the watermarked result", %{config: config} do
      later = image("wm=logo/-/w=30", config)
      inside = image("w=30/wm=logo", config)
      assert dimensions(later) == {30, 20}
      assert dimensions(inside) == {30, 20}
      refute pixels(later) == pixels(inside)
    end
  end

  describe "alpha" do
    test "asset alpha, host base opacity, and request opacity multiply", %{config: config} do
      marked = image("wm=ghost/wm-opacity=0.5", config)
      [red, green, blue] = pixel(marked, 30, 20)
      # 128/255 asset alpha × 0.5 host × 0.5 request ≈ 0.125 coverage.
      assert_in_delta red, 32, 2
      assert green == 0
      assert_in_delta blue, 223, 2
      assert VipsImage.bands(marked) == 3
    end

    test "a transparent frame gains coverage only where the asset is opaque", %{config: config} do
      marked = image("pad=10/wm=logo/wm-at=top-left", config)
      assert VipsImage.bands(marked) == 4
      assert pixel(marked, 0, 0) == @red ++ [255]
      assert List.last(pixel(marked, 15, 0)) == 0
    end
  end

  describe "tiled watermark materialization" do
    test "the resized and faded asset is buffered once only for tiling", context do
      config = observed_mount(context)

      assert response("wm=pattern/wm-scale=0.2/wm-opacity=0.6/wm-tile", config).status ==
               200

      assert_received {:materialized, %{dims: {8, 8}, result: :ok}}
      refute_received {:materialized, %{dims: {8, 8}}}

      assert response("wm=pattern/wm-scale=0.2/wm-opacity=0.6", config).status == 200
      refute_received {:materialized, %{dims: {8, 8}}}
    end

    test "scaled translucent tiles match individually placed marks", %{config: config} do
      mark = "wm=pattern/wm-scale=0.2/wm-opacity=0.6/wm-at=top-left"
      tiled = image(mark <> "/wm-tile/wm-offset=-3,-2/wm-gap=20,20", config)

      placements =
        for y <- -2..39//28, x <- -3..59//28 do
          mark <> "/wm-offset=#{x},#{y}"
        end

      expected = image(Enum.join(placements, "/-/"), config)
      assert dimensions(tiled) == {60, 40}
      assert pixels(tiled) == pixels(expected)
    end

    test "a corrupt asset fails as a decode error inside the watermark operation", context do
      body =
        "priv/static/images/beach.jpg"
        |> Image.open!()
        |> Image.write!(:memory, suffix: ".jpg", strip_metadata: true)
        |> binary_part(0, 5000)

      origin = origin(%{"image.png" => png(Image.new!(60, 40, color: @blue)), "mark.jpg" => body})
      context = %{context | origin: origin}
      config = observed_mount(context, watermarks: %{logo: [source: "mark.jpg"]})

      result = response("wm=logo/wm-scale=0.2/wm-tile", config)
      assert result.status == 415, result.resp_body
      assert_received {:watermark_result, :error}
      assert_received {:materialized, %{result: :materialize_error}}
    end

    test "a corrupt asset fails as a decode error when color management changes a profile",
         context do
      photo = File.read!("priv/static/images/beach.jpg")

      stripped =
        photo
        |> Image.from_binary!()
        |> Image.write!(:memory, suffix: ".jpg", strip_metadata: true)

      # A profiled asset on an untagged frame drops its profile. An untagged
      # asset on a tagged frame takes the frame's profile.
      for {asset, source} <- [
            {binary_part(photo, 0, 5000), "src/image.png"},
            {binary_part(stripped, 0, 5000), "src/photo.jpg"}
          ] do
        files = %{
          "image.png" => png(Image.new!(60, 40, color: @blue)),
          "photo.jpg" => photo,
          "mark.jpg" => asset
        }

        context = %{context | origin: origin(files)}
        config = observed_mount(context, watermarks: %{logo: [source: "mark.jpg"]})

        result = response("w=60/wm=logo/wm-scale=0.2", config, source)
        assert result.status == 415, result.resp_body
        assert_received {:materialized, %{result: :materialize_error}}
        :telemetry.detach({__MODULE__, context.test, self()})
      end
    end
  end

  test "a color asset promotes a grayscale frame to RGB", %{config: config} do
    gray = image("gray", config)
    marked = image("gray/wm=logo", config)
    assert VipsImage.interpretation(gray) == :VIPS_INTERPRETATION_B_W
    assert VipsImage.interpretation(marked) == :VIPS_INTERPRETATION_sRGB
    assert pixel(marked, 30, 20) == @red
    assert pixel(marked, 0, 0) == List.duplicate(hd(pixel(gray, 0, 0)), 3)
  end

  for policy <- ["", "/profile=preserve"] do
    test "a color asset promotes a tagged grayscale frame to untagged sRGB (#{policy})", %{
      config: config
    } do
      response = response("wm=logo" <> unquote(policy), config, "src/tagged_gray.png")
      marked = Image.from_binary!(response.resp_body)

      assert VipsImage.interpretation(marked) == :VIPS_INTERPRETATION_sRGB
      assert VipsImage.header_value(marked, "icc-profile-data") |> elem(0) == :error
      assert pixel(marked, 30, 20) == @red
    end
  end

  test "a color asset on a truncated tagged grayscale frame fails as a decode error" do
    {:ok, gray} =
      400
      |> Image.linear_gradient!(300, start_color: :navy, finish_color: :orange)
      |> VipsOperation.colourspace(:VIPS_INTERPRETATION_B_W)

    {:ok, tagged} = VipsOperation.icc_transform(gray, "sGrey", input_profile: "sGrey")
    jpeg = Image.write!(tagged, :memory, suffix: ".jpg", strip_metadata: false)

    files = %{
      "frame.jpg" => binary_part(jpeg, 0, div(byte_size(jpeg), 2)),
      "mark.png" => png(Image.new!(10, 10, color: @red))
    }

    config = mount(origin(files))

    assert response("wm=logo", config, "src/frame.jpg").status == 415
  end

  test "a grayscale asset keeps a grayscale frame gray", %{config: config} do
    marked = image("gray/wm=gray_logo", config)
    assert VipsImage.interpretation(marked) == :VIPS_INTERPRETATION_B_W
    assert VipsImage.bands(marked) == 1
  end

  test "assets follow a preserved high-bit-depth working space", %{config: config} do
    response = response("hdr=preserve/wm=logo", config, "src/deep.png")
    assert response.status == 200
    marked = Image.from_binary!(response.resp_body)
    assert VipsImage.format(marked) == :VIPS_FORMAT_USHORT
    assert pixel(marked, 30, 20) == [65_535, 0, 0]
    assert pixel(marked, 0, 0) == [0, 0, 65_535]
  end

  test "8-bit asset values scale to the full 16-bit range", %{config: config} do
    marked =
      Image.from_binary!(response("hdr=preserve/wm=mid_logo", config, "src/deep.png").resp_body)

    assert pixel(marked, 30, 20) == [257, 128 * 257, 200 * 257]
  end

  test "EXIF orientation applies to the asset", %{config: config} do
    marked = image("wm=turned/wm-at=top-left", config)
    assert dominant(pixel(marked, 3, 5)) == :red
    assert dominant(pixel(marked, 16, 5)) == :green
    assert pixel(marked, 21, 5) == @blue
  end

  test "watermarks change placeholder outputs", %{config: config} do
    for terminal <- ["blurhash", "lqip-css"] do
      plain = response("output=#{terminal}", config, "src/image.png")
      marked = response("output=#{terminal}/wm=logo/wm-scale=1", config, "src/image.png")
      assert plain.status == 200 and marked.status == 200
      refute plain.resp_body == marked.resp_body
    end
  end

  describe "request sources" do
    test "a request source matches the named asset it points to", %{config: config} do
      named = response("wm=logo", config)
      sourced = response("wm-src64=#{Base.url_encode64("mark.png", padding: false)}", config)
      assert named.resp_body == sourced.resp_body
      assert etag(named) == etag(sourced)
    end

    test "a concealed source decrypts like the main source", %{origin: origin} do
      url_options = [keys: [@signing_key], source_encryption_keys: [@source_key]]
      url = ImagePipe.URL.config(url_options)
      config = mount(origin, url_options)
      {:ok, token} = ImagePipe.Security.encrypt_source("mark.png", url.options, [])

      signed = fn options ->
        path = ImagePipe.URL.sign_path("/#{options}/format=png/src/image.png", url)
        conn(:get, path) |> ImagePipe.Plug.call(config)
      end

      concealed = signed.("wm-enc=#{token}")
      assert concealed.status == 200
      assert concealed.resp_body == signed.("wm=logo").resp_body
      assert signed.("wm-enc=#{String.reverse(token)}").status == 404
    end

    test "a concealed source on a mount without encryption keys is a 400", %{origin: origin} do
      url = ImagePipe.URL.config(keys: [@signing_key], source_encryption_keys: [@source_key])
      {:ok, token} = ImagePipe.Security.encrypt_source("mark.png", url.options, [])
      plain_url = ImagePipe.URL.config(keys: [@signing_key])
      plain = mount(origin, keys: [@signing_key])
      path = ImagePipe.URL.sign_path("/wm-enc=#{token}/format=png/src/image.png", plain_url)
      response = conn(:get, path) |> ImagePipe.Plug.call(plain)

      assert response.status == 400

      assert response.resp_body =~
               "wm-enc is not accepted: no source encryption keys are configured"

      refute_received {:origin_fetch, _path}
    end

    test "a concealed watermark from a looked-up preset on a mount without encryption keys is a 400",
         %{origin: origin} do
      url = ImagePipe.URL.config(keys: [@signing_key], source_encryption_keys: [@source_key])
      {:ok, token} = ImagePipe.Security.encrypt_source("mark.png", url.options, [])
      lookup = [presets: %{"wm" => "wm-enc=#{token}"}, test_pid: self()]
      plain = mount(origin, preset_lookup: {ImagePipe.Test.PresetLookup, lookup})
      response = conn(:get, "/preset=wm/format=png/src/image.png") |> ImagePipe.Plug.call(plain)

      assert response.status == 400

      assert response.resp_body =~
               "wm-enc is not accepted: no source encryption keys are configured"

      refute_received {:origin_fetch, _path}
    end

    test "parse failures return before any source access", %{origin: origin, config: config} do
      gated = mount(origin, request_watermarks: false)
      source = Base.url_encode64("mark.png", padding: false)

      for {options, config} <- [
            {"wm=unknown", config},
            {"wm-src64=#{source}", gated}
          ] do
        assert response(options, config).status == 400, options
        refute_received {:origin_fetch, _path}
      end
    end
  end

  describe "asset failures" do
    test "a missing asset fails like a missing main source", %{config: config} do
      missing = response("", config, "src/missing.png")
      asset = response("wm-src64=#{Base.url_encode64("missing.png", padding: false)}", config)
      assert asset.status == missing.status
      assert asset.status in 400..599
    end

    test "an undecodable asset fails as unsupported media", %{config: config} do
      assert response("wm=corrupt", config).status == 415
    end
  end

  describe "identity and conditional requests" do
    test "renaming a host entry keeps identity; base opacity folds in", %{origin: origin} do
      first = mount(origin, watermarks: %{logo: [source: "mark.png", opacity: 0.5]})
      renamed = mount(origin, watermarks: %{brand: [source: "mark.png", opacity: 0.5]})
      assert etag(response("wm=logo", first)) == etag(response("wm=brand", renamed))

      assert etag(response("wm=logo/wm-opacity=0.5", mount(origin))) ==
               etag(response("wm=logo", first))

      refute etag(response("wm=logo", mount(origin))) == etag(response("wm=logo", first))
    end

    test "a conditional GET answers 304 before fetching either source", %{config: config} do
      etag = etag(response("wm=logo", config))
      flush_fetches()

      conditional =
        conn(:get, "/wm=logo/format=png/src/image.png")
        |> put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(config)

      assert conditional.status == 304
      refute_received {:origin_fetch, _path}
    end

    test "an uncached main source is fetched while the asset is read" do
      test = self()
      blocked = png(Image.new!(10, 10, color: @red))

      origin = fn conn ->
        case conn.path_info do
          ["slow.png"] ->
            send(test, {:asset_blocked, self()})

            receive do
              :continue -> :ok
            end

            conn |> put_resp_content_type("image/png") |> send_resp(200, blocked)

          ["image.png"] ->
            send(test, :main_fetch)

            conn
            |> put_resp_content_type("image/png")
            |> send_resp(200, png(Image.new!(60, 40, color: @blue)))
        end
      end

      config = mount(origin, watermarks: %{logo: [source: "slow.png"]})
      request = Task.async(fn -> response("wm=logo", config) end)

      assert_receive {:asset_blocked, asset}, 5_000
      assert_receive :main_fetch, 5_000
      send(asset, :continue)
      assert Task.await(request).status == 200
    end

    test "an asset used by several groups is fetched once", %{config: config} do
      flush_fetches()
      assert response("wm=logo/-/wm=logo/wm-at=top-left", config).status == 200
      assert_received {:origin_fetch, "mark.png"}
      refute_received {:origin_fetch, "mark.png"}
    end
  end

  defp response(options, config, source \\ "src/image.png") do
    path =
      [options, if(options =~ "output=", do: "", else: "format=png"), source]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("/")

    conn(:get, "/" <> path) |> ImagePipe.Plug.call(config)
  end

  defp image(options, config) do
    response = response(options, config)
    assert response.status == 200, "#{options}: HTTP #{response.status} #{response.resp_body}"
    Image.from_binary!(response.resp_body)
  end

  defp etag(response) do
    assert [etag] = get_resp_header(response, "etag")
    etag
  end

  defp gray_mark do
    {:ok, mark} = VipsOperation.black(10, 10)
    {:ok, mark} = VipsOperation.linear(mark, [1.0], [200.0])
    {:ok, mark} = VipsOperation.cast(mark, :VIPS_FORMAT_UCHAR)
    {:ok, mark} = VipsOperation.copy(mark, interpretation: :VIPS_INTERPRETATION_B_W)
    mark
  end

  defp tagged_gray do
    {:ok, gray} =
      VipsOperation.colourspace(Image.new!(60, 40, color: @blue), :VIPS_INTERPRETATION_B_W)

    {:ok, tagged} = VipsOperation.icc_transform(gray, "sGrey", input_profile: "sGrey")
    tagged
  end

  defp pixel(image, {x, y}), do: pixel(image, x, y)
  defp pixel(image, x, y), do: image |> Image.get_pixel!(x, y) |> Enum.map(&round/1)
  defp dimensions(image), do: {Image.width(image), Image.height(image)}
  defp pixels(image), do: VipsImage.write_to_binary(image)

  defp pattern_mark do
    bytes = for y <- 0..19, x <- 0..19, into: <<>>, do: <<x * 12, y * 12, 80, 80 + x * 8>>
    {:ok, mark} = VipsImage.new_from_binary(bytes, 20, 20, 4, :VIPS_FORMAT_UCHAR)
    VipsOperation.copy!(mark, interpretation: :VIPS_INTERPRETATION_sRGB)
  end

  defp observed_mount(context, options \\ []) do
    prefix = [__MODULE__, context.test]
    id = {__MODULE__, context.test, self()}

    :ok =
      :telemetry.attach_many(
        id,
        [prefix ++ [:transform, :materialize, :stop], prefix ++ [:transform, :operation, :stop]],
        &__MODULE__.watermark_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    mount(context.origin, Keyword.put(options, :telemetry_prefix, prefix))
  end

  def watermark_event(
        [__MODULE__, _test, :transform, :materialize, :stop],
        _measurements,
        metadata,
        pid
      ),
      do: send(pid, {:materialized, metadata})

  def watermark_event(
        [__MODULE__, _test, :transform, :operation, :stop],
        _measurements,
        metadata,
        pid
      ) do
    case metadata do
      %{operation: :watermark, result: result} -> send(pid, {:watermark_result, result})
      _other -> :ok
    end
  end

  defp dominant([red, green, _blue]) when red > 200 and green < 60, do: :red
  defp dominant([red, green, _blue]) when green > 200 and red < 60, do: :green
  defp dominant(pixel), do: pixel

  defp flush_fetches do
    receive do
      {:origin_fetch, _path} -> flush_fetches()
    after
      0 -> :ok
    end
  end

  defp mount(origin, options \\ []) do
    ImagePipe.Plug.init(
      [
        sources: [
          path: [
            match: :path,
            adapter: RootHTTPAdapter,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        watermarks: %{
          logo: [source: "mark.png"],
          ghost: [source: "alpha.png", opacity: 0.5],
          pattern: [source: "pattern.png"],
          gray_logo: [source: "gray_mark.png"],
          mid_logo: [source: "mid_mark.png"],
          turned: [source: "rotated.jpg"],
          corrupt: [source: "corrupt.png"]
        },
        request_watermarks: true,
        http_cache: :auto
      ]
      |> Keyword.merge(options)
    )
  end

  defp origin(files) do
    pid = self()

    fn conn ->
      path = Enum.join(conn.path_info, "/")
      send(pid, {:origin_fetch, path})

      case Map.fetch(files, path) do
        {:ok, body} -> conn |> put_resp_content_type("image/png") |> send_resp(200, body)
        :error -> send_resp(conn, 404, "missing")
      end
    end
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  defp deep_png do
    {:ok, image} = Image.new(60, 40, color: [0, 0, 65_535], format: {:u, 16})
    {:ok, image} = VipsOperation.copy(image, interpretation: :VIPS_INTERPRETATION_RGB16)
    png(image)
  end

  # Stored 10×20 with green above red; EXIF orientation 6 displays it as 20×10
  # with red on the left.
  defp rotated_jpeg do
    image =
      Image.new!(10, 20, color: @red)
      |> Image.Draw.rect!(0, 0, 10, 10, color: @green)

    {:ok, image} =
      VipsImage.mutate(image, fn mutable -> MutableImage.set(mutable, "orientation", :gint, 6) end)

    Image.write!(image, :memory, suffix: ".jpg", quality: 100, strip_metadata: false)
  end
end

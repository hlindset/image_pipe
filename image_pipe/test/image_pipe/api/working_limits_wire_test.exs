defmodule ImagePipe.API.WorkingLimitsWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.ProcessingSource
  alias Vix.Vips.Image, as: VipsImage

  @image Image.new!(43, 64, color: :red)
         |> Image.Draw.rect!(10, 30, 33, 34, color: :blue, fill: true)
         |> Image.write!(:memory, suffix: ".png")

  test "unsupported numeric values fail before fetching or touching the cache" do
    mount = mount(CacheObserver.observe([]))

    for options <- [
          "blur=1001",
          "progressive-blur=1001",
          "sharpen=0.0000001",
          "sharpen=10.1",
          "w=#{String.duplicate("9", 400)}",
          "min-w=#{String.duplicate("9", 400)}",
          "pad=3000000000",
          "dpr=2147483648",
          "zoom=2147483648"
        ] do
      assert request(mount, options).status == 400
    end

    refute_received {:fetch, _, _}
    refute_received {:cache_lookup, _, _hash}
    refute_received {:cache_put, _hash, _body}
  end

  test "oversized work is rejected before final clamping or materialization" do
    for options <- [
          "w=500/h=500/fit=stretch/enlarge",
          "pad=1000",
          "w=500/h=500/extend",
          "w=100/dpr=50/enlarge",
          "w=500/h=500/fit=stretch/enlarge/-/rotate=90",
          "w=500/h=500/fit=stretch/enlarge/-/trim=auto",
          "w=500/h=500/fit=stretch/enlarge/-/progressive-blur=2",
          "w=500/h=500/fit=stretch/enlarge/-/pixelate=10"
        ] do
      result = request(mount(), options)
      assert result.status == 422, options
      assert result.resp_body == "intermediate image exceeds the pixel limit"
    end
  end

  test "a lazy oversized frame followed by a small crop retains its coordinates and pixels" do
    result = request(mount(), "w=500/h=500/fit=stretch/enlarge/-/region=123,456,32,24")
    assert result.status == 200
    actual = Image.from_binary!(result.resp_body)

    expected =
      @image
      |> Image.from_binary!()
      |> Image.resize!(500 / 43, vertical_scale: 500 / 64)
      |> Image.crop!(123, 456, 32, 24)

    assert {Image.width(actual), Image.height(actual)} == {32, 24}
    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  test "downsampling an oversized lazy frame fails even when the final frame is tiny" do
    result = request(mount(), "w=500/h=500/fit=stretch/enlarge/-/w=32/h=24/fit=stretch")
    assert result.status == 422
  end

  test "full-frame operations guard lazy results even after an earlier memory buffer" do
    result =
      request(
        mount(),
        "rotate=90/progressive-blur=1/-/w=500/h=500/fit=stretch/enlarge/-/trim=auto/output=info"
      )

    assert result.status == 422
  end

  test "the work limit can be configured independently of the final clamp" do
    config = mount(max_intermediate_pixels: 20_000, max_result_pixels: 1_000)
    assert request(config, "w=200/h=100/fit=stretch/enlarge").status == 200
    assert request(config, "w=201/h=100/fit=stretch/enlarge").status == 422

    # A previous orientation flush makes the input RAM-backed. The lazy result
    # still needs a final guard even when delivery can skip its memory copy.
    config = mount(max_intermediate_pixels: 20_000, max_result_pixels: 100_000)
    assert request(config, "rotate=90/-/w=201/h=100/fit=stretch/enlarge").status == 422
  end

  test "DPR and padding combinations obey native construction limits" do
    for options <- [
          "pad=1000000000/dpr=2",
          "w=2147483647/h=1/fit=stretch/enlarge/dpr=2",
          "w=2147483647/h=1/fit=stretch/enlarge"
        ] do
      assert request(mount(), options).status == 422
    end
  end

  test "invalid work-limit configuration fails before source access" do
    for value <- [0, -1, :infinity] do
      assert_raise ArgumentError, fn -> mount(max_intermediate_pixels: value) end
    end

    refute_received {:fetch, _, _}
  end

  test "placeholder reductions enforce the input work limit" do
    for terminal <- ["blurhash", "lqip-css", "info,blurhash,lqip-css"] do
      assert request(mount(), "w=500/h=500/fit=stretch/enlarge/output=#{terminal}").status == 422
    end
  end

  test "a lower work limit preserves cache identity and serves an existing successful response" do
    cache = CacheObserver.observe([])
    options = "w=32/h=24/fit=stretch"
    original = request(mount(cache), options)
    assert original.status == 200
    assert [_etag] = Plug.Conn.get_resp_header(original, "etag")
    assert_receive {:fetch, _, _}

    cached =
      request(mount(cache ++ [max_intermediate_pixels: 100]), options)

    assert cached.status == 200
    assert cached.resp_body == original.resp_body

    assert Plug.Conn.get_resp_header(cached, "etag") ==
             Plug.Conn.get_resp_header(original, "etag")

    refute_received {:fetch, _, _}
  end

  test "watermark tile cells obey native geometry limits" do
    config = mount(watermarks: %{logo: [source: "ready"]})
    assert request(config, "wm=logo/wm-tile/wm-gap=2147483647,0").status == 422
    assert request(config, "wm=logo/dpr=2147483647").status == 422
  end

  defp mount(extra \\ []) do
    config =
      ImagePipe.config(
        Keyword.merge(
          [
            max_intermediate_pixels: 100_000,
            sources: [
              path: [
                adapter: ProcessingSource,
                match: :path,
                options: [test: self(), bytes: @image]
              ]
            ]
          ],
          extra
        )
      )

    ImagePipe.Plug.init(config: config)
  end

  defp request(mount, options),
    do: ImagePipe.Plug.call(conn(:get, "/#{options}/format=png/src/ready"), mount)
end

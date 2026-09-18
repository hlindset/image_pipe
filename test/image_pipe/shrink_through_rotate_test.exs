defmodule ImagePipe.ShrinkThroughRotateTest do
  # Real image encode/decode per case — keep it serial.
  use ExUnit.Case, async: false

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.Native
  alias ImagePipe.Native.Pipeline
  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Source, as: NativeSource
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.State

  # Shrink-on-load through a preceding 90/270 user rotate (#151, the B2 extension).
  # Today a quarter-turn rotate before the resize forces a full-resolution decode;
  # this exercises the imgproxy-parity path where the JPEG is shrunk on load and the
  # shrink axes are swapped to match the combined net orientation turn (ExtractGeometry
  # `(angle + baseAngle) % 180`). Output must stay pixel-equivalent (±1px each axis,
  # perceptually identical) to the full-decode path.
  #
  # Equivalence is proven against the SAME source encoded as PNG, which is not
  # shrink-eligible and therefore decodes full-resolution. Any divergence beyond the
  # resampling floor is attributable to the axis swap / shrink interaction.

  # A structured source so a misplaced/transposed rotate shows up as pixel
  # differences. Distinguishable rectangles at known positions: top-left red,
  # bottom-right green, centred blue marker. Solid colours would hide a wrong axis swap.
  defp structured(width, height, suffix) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), div(height, 2), div(width, 2), div(height, 2),
      color: [40, 240, 40]
    )
    |> Image.Draw.rect!(div(width, 4), div(height, 4), div(width, 2), div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.write!(:memory, suffix: suffix)
  end

  defp oriented(width, height, orientation, suffix) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), div(height, 2), div(width, 2), div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.set_orientation!(orientation)
    |> Image.write!(:memory, suffix: suffix)
  end

  # Parse a real native request, fetch and decode through the shared bracket,
  # then run it through the native pipeline — the same seams the Plug drives.
  defp run(body, options) do
    opts = opts(body)
    request = request(options, opts)
    {:ok, source_request} = NativeSource.translate(request.source, opts)
    {:ok, source} = Source.resolve(source_request, opts, [])

    Decode.with_image(
      source,
      Keyword.put(opts, :auto_rotate?, true),
      &Pipeline.decode_request(request, &1),
      fn state, geometry ->
        {:ok, %State{} = final} = Pipeline.run(state, geometry, request, opts)
        {final.image, shrink_factor(state.decode_shrink)}
      end
    )
  end

  defp run_imgproxy(body, options) do
    telemetry_prefix = [:"shrink_rotate_#{System.unique_integer([:positive])}"]
    decode_stop = telemetry_prefix ++ [:source, :fetch_decode, :stop]
    handler_id = {__MODULE__, self(), telemetry_prefix}

    :telemetry.attach(
      handler_id,
      decode_stop,
      &__MODULE__.handle_decode_stop/4,
      {self(), telemetry_prefix}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    opts =
      body
      |> mount_options()
      |> Keyword.put(:telemetry_prefix, telemetry_prefix)
      |> Keyword.put(:dialect, Imgproxy)
      |> ImagePipe.Plug.init()

    conn =
      :get
      |> Plug.Test.conn("/_/#{options}/f:png/plain/rot.img")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_receive {:decode_stop, ^telemetry_prefix, metadata}

    {Image.from_binary!(conn.resp_body), load_shrink(Map.get(metadata, :load_option))}
  end

  def handle_decode_stop(_event, _measurements, metadata, {test_pid, telemetry_prefix}) do
    send(test_pid, {:decode_stop, telemetry_prefix, metadata})
  end

  defp request(options, opts) do
    assert {{:ok, %Request{} = request}, _metadata} =
             Native.parse(Plug.Test.conn(:get, "/#{options}/src/rot.img"), opts)

    request
  end

  # The realized load shrink, rounded back to the libjpeg block factor the
  # planner asked for. `nil` when the decode was not shrunk at all.
  defp shrink_factor(nil), do: nil
  defp shrink_factor(%{w: w}), do: round(w)

  defp load_shrink(nil), do: nil
  defp load_shrink({:shrink, factor}), do: factor

  defp opts(body) do
    body
    |> mount_options()
    |> ImagePipe.Plug.init()
  end

  defp mount_options(body) do
    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: origin_plug(body)]}
      ],
      max_input_pixels: 100_000_000,
      max_result_width: 100_000,
      max_result_height: 100_000,
      max_result_pixels: 1_000_000_000,
      max_body_bytes: 100_000_000
    ]
  end

  defp origin_plug(body) do
    content_type =
      case body do
        <<0xFF, 0xD8, _rest::binary>> -> "image/jpeg"
        _other -> "image/png"
      end

    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # Mean absolute error across all pixels/bands, after downsampling both to ~48px
  # wide. Coarse enough to be insensitive to sub-pixel decode-kernel differences,
  # fine enough to catch a transposed (wrongly-swapped) result.
  defp coarse_mae(img_a, img_b) do
    target_w = 48
    {:ok, ds_a} = Image.resize(img_a, target_w / Image.width(img_a))
    {:ok, ds_b} = Image.resize(img_b, target_w / Image.width(img_b))

    w = min(Image.width(ds_a), Image.width(ds_b))
    h = min(Image.height(ds_a), Image.height(ds_b))
    bands = length(Image.get_pixel!(ds_a, 0, 0))

    total =
      for x <- 0..(w - 1), y <- 0..(h - 1), reduce: 0 do
        acc ->
          pa = Image.get_pixel!(ds_a, x, y)
          pb = Image.get_pixel!(ds_b, x, y)
          acc + (Enum.zip(pa, pb) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.sum())
      end

    total / (w * h * bands)
  end

  defp assert_equivalent(jpeg_img, png_img, shrink, label) do
    assert shrink in [2, 4, 8],
           "expected JPEG shrink to fire for #{label}, got #{inspect(shrink)}"

    jw = Image.width(jpeg_img)
    jh = Image.height(jpeg_img)
    pw = Image.width(png_img)
    ph = Image.height(png_img)

    assert abs(jw - pw) <= 1 and abs(jh - ph) <= 1,
           "shrink path #{jw}x#{jh} drifted >1px from full-decode #{pw}x#{ph} for #{label} (shrink #{shrink})"

    mae = coarse_mae(jpeg_img, png_img)

    assert mae < 4.0,
           "shrink-through-rotate coarse MAE #{mae} exceeds 4.0 for #{label} — output likely transposed"
  end

  # 3200×3200 square source so a width-only fit:400 drives load_shrink ~8 regardless
  # of the axis swap; a quarter turn does not change the realized shrink scalar.
  @src 3200

  describe "user quarter-turn rotate then resize (no EXIF)" do
    for angle <- [90, 270] do
      test "rot:#{angle} + fit resize is pixel-equivalent across shrink and full decode" do
        angle = unquote(angle)
        options = "rotate=#{angle}/w=400/h=400"

        {jpeg_img, shrink} = run(structured(@src, @src, ".jpg"), options)
        {png_img, no_shrink} = run(structured(@src, @src, ".png"), options)

        assert no_shrink == nil, "PNG baseline must not shrink"
        assert_equivalent(jpeg_img, png_img, shrink, "rot:#{angle} -> fit:400:400")
      end
    end

    # rot:180 swaps no axes but must still shrink correctly. Use a non-square source
    # and a width-only fit so a wrongly-applied swap would change the dims.
    test "rot:180 + fit resize shrinks without swapping (non-square source)" do
      {jpeg_img, shrink} = run(structured(3200, 2400, ".jpg"), "rotate=180/w=400")
      {png_img, no_shrink} = run(structured(3200, 2400, ".png"), "rotate=180/w=400")

      assert no_shrink == nil
      assert_equivalent(jpeg_img, png_img, shrink, "rot:180 -> fit:400")
    end
  end

  describe "combined EXIF orientation + user rotate (net turn drives the swap)" do
    # EXIF-6 (90°) source + user rot:90 = net 180 → NO swap. Displayed image is the
    # stored image turned 180 (still landscape). A width-only fit must still land
    # the right dims, proving the net-turn determination (not EXIF alone).
    test "EXIF-6 + rot:90 = net 180 (no swap) stays pixel-equivalent" do
      {jpeg_img, shrink} = run(oriented(3200, 2400, 6, ".jpg"), "rotate=90/w=400")
      {png_img, no_shrink} = run(oriented(3200, 2400, 6, ".png"), "rotate=90/w=400")

      assert no_shrink == nil
      assert_equivalent(jpeg_img, png_img, shrink, "EXIF-6 + rot:90 net-180 -> fit:400")
    end

    # EXIF-6 (90°) source + user rot:180 = net 90 → SWAP. Stored 3200×2400; net 90
    # displays it portrait 2400×3200, so a width-only fit:400 targets the displayed
    # width 2400. A missing swap would size against 3200 and over-shrink.
    test "EXIF-6 + rot:180 = net 90 (swap) stays pixel-equivalent" do
      {jpeg_img, shrink} = run(oriented(3200, 2400, 6, ".jpg"), "rotate=180/w=400")
      {png_img, no_shrink} = run(oriented(3200, 2400, 6, ".png"), "rotate=180/w=400")

      assert no_shrink == nil
      assert_equivalent(jpeg_img, png_img, shrink, "EXIF-6 + rot:180 net-90 -> fit:400")
    end
  end

  describe "crop + rotate + resize (B1 ∘ B2)" do
    test "gravity crop + rot:90 + resize composes B1 and B2" do
      options = "rot:90/c:1600:1600:nowe:600:400/rs:fit:400:400"

      {jpeg_img, shrink} = run_imgproxy(structured(@src, @src, ".jpg"), options)
      {png_img, no_shrink} = run_imgproxy(structured(@src, @src, ".png"), options)

      assert no_shrink == nil
      assert_equivalent(jpeg_img, png_img, shrink, "rot:90 + gravity crop -> fit:400:400")
    end
  end

  describe "decode-limit guardrail" do
    # An over-limit source with a rotate+resize that WOULD shrink must STILL fail the
    # input-pixel gate: validate_original_pixels keys off the un-shrunk header dims
    # read before the shrink-aware open. Shrink-through-rotate must not smuggle an
    # over-budget source past the limit.
    test "over-limit JPEG with rotate+resize is rejected before decode" do
      body = structured(@src, @src, ".jpg")
      opts = opts(body)
      request = request("rotate=90/w=400/h=400", opts)

      over_limit =
        opts
        |> Keyword.put(:max_input_pixels, @src * @src - 1)
        |> Keyword.put(:auto_rotate?, true)

      {:ok, source_request} = NativeSource.translate(request.source, over_limit)
      {:ok, source} = Source.resolve(source_request, over_limit, [])

      assert {:error, {:input_limit, {:too_many_input_pixels, pixels, limit}}} =
               Decode.with_image(
                 source,
                 over_limit,
                 &Pipeline.decode_request(request, &1),
                 fn _state, _geometry ->
                   flunk("decode must not run past the pixel-limit gate")
                 end
               )

      assert pixels == @src * @src
      assert limit == @src * @src - 1
    end
  end
end

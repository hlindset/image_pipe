defmodule ImagePipe.Dialect.Imgproxy.OrientationStageWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  test "gradient runs in the display frame after EXIF orientation" do
    base = marked(40, 80)
    path = "/_/gr:1:000000:down/f:png/plain/image.jpg"

    oriented = image(path, {OrientedFrameOrigin, {base, 6}})
    twin = image(path, {Orientation1TwinOrigin, {base, 6}})

    assert {Image.width(oriented), Image.height(oriented)} ==
             {Image.width(twin), Image.height(twin)}

    assert VipsImage.write_to_binary(oriented) == VipsImage.write_to_binary(twin)
  end

  test "asymmetric padding lands on display-frame sides after EXIF orientation" do
    assert_display_frame_parity(
      "/_/pd:10:4:2:8/f:png/plain/image.jpg",
      "asymmetric padding"
    )
  end

  test "pixelate aligns partial blocks in the display frame after EXIF orientation" do
    assert_display_frame_parity(
      "/_/pix:7/f:png/plain/image.jpg",
      "non-divisible pixelate grid"
    )
  end

  test "equal-horizontal trim runs in the storage frame before EXIF orientation" do
    base = trim_source()
    actual = image("/_/t:10::1:0/f:png/plain/image.jpg", {OrientedFrameOrigin, {base, 6}})
    expected = trim_storage_then_orient(base, 6, equal_hor: true)

    assert {Image.width(actual), Image.height(actual)} ==
             {Image.width(expected), Image.height(expected)}

    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  test "automatic trim background samples the storage-frame top-left corner" do
    base = smart_trim_source()
    actual = image("/_/t:10/f:png/plain/image.jpg", {OrientedFrameOrigin, {base, 6}})
    expected = trim_storage_then_orient(base, 6)

    assert {Image.width(actual), Image.height(actual)} ==
             {Image.width(expected), Image.height(expected)}

    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  test "a real fractional-DPR request rounds padding sides half to even" do
    telemetry_prefix = [:"imgproxy_padding_round_#{System.unique_integer([:positive])}"]
    event = telemetry_prefix ++ [:transform, :operation, :start]
    handler_id = {__MODULE__, self(), telemetry_prefix}

    :telemetry.attach(
      handler_id,
      event,
      &__MODULE__.handle_operation_start/4,
      {self(), telemetry_prefix}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    response =
      request(
        "/_/el:1/dpr:0.5/pd:1:3:5:7/f:png/plain/image.png",
        png_origin(marked(10, 10)),
        telemetry_prefix: telemetry_prefix
      )

    assert response.status == 200

    assert_receive {:operation_start, ^telemetry_prefix,
                    %{operation: :padding, params: %Padding{} = padding}}

    assert %Padding{top: 0, right: 2, bottom: 2, left: 4} = padding
  end

  def handle_operation_start(_event, _measurements, metadata, {test_pid, telemetry_prefix}) do
    send(test_pid, {:operation_start, telemetry_prefix, metadata})
  end

  defp request(path, origin, extra \\ []) do
    config =
      ImagePipe.Plug.init(
        [
          dialect: Imgproxy,
          sources: [
            path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
          ],
          max_body_bytes: 10_000_000,
          max_input_pixels: 40_000_000
        ] ++ extra
      )

    conn(:get, path) |> ImagePipe.Plug.call(config)
  end

  defp image(path, origin) do
    response = request(path, origin)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp assert_display_frame_parity(path, label) do
    base = marked(40, 80)

    for orientation <- 1..8 do
      oriented = image(path, {OrientedFrameOrigin, {base, orientation}})
      twin = image(path, {Orientation1TwinOrigin, {base, orientation}})

      assert {Image.width(oriented), Image.height(oriented)} ==
               {Image.width(twin), Image.height(twin)},
             "#{label} EXIF #{orientation}: dimensions differ"

      assert VipsImage.write_to_binary(oriented) == VipsImage.write_to_binary(twin),
             "#{label} EXIF #{orientation}: pixels differ"
    end
  end

  defp png_origin(body) do
    fn conn ->
      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, body)
    end
  end

  defp marked(width, height) do
    width
    |> Image.new!(height, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, div(width, 2), div(height, 2), color: [240, 40, 40])
    |> Image.Draw.rect!(div(width, 2), 0, width - div(width, 2), div(height, 2),
      color: [40, 240, 40]
    )
    |> Image.Draw.rect!(0, div(height, 2), div(width, 2), height - div(height, 2),
      color: [40, 40, 240]
    )
    |> Image.write!(:memory, suffix: ".png")
  end

  defp trim_source do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(4, 10, 10, 8, color: :red)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp smart_trim_source do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(10, 20, 16, 40, color: :red)
    |> Image.Draw.rect!(0, 0, 8, 8, color: :black)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp trim_storage_then_orient(base, orientation, opts \\ []) do
    storage =
      base
      |> Image.open!(access: :random)
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")
      |> Image.open!(access: :random, fail_on: :error)

    raw = Image.set_orientation!(storage, 1)

    op = %Trim{
      threshold: 10.0,
      background: :auto,
      equal_hor: Keyword.get(opts, :equal_hor, false),
      equal_ver: Keyword.get(opts, :equal_ver, false)
    }

    {:ok, %State{image: trimmed}} =
      Trim.execute(op, %State{image: raw, materialized?: true})

    {:ok, {oriented, _flags}} =
      trimmed
      |> Image.set_orientation!(orientation)
      |> Image.autorotate()

    oriented
  end
end

defmodule ImagePipe.API.OrientationPolicyWireTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Test.PlugFixture.CountingOriginImage
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage, as: VipsMutableImage

  @orientations 1..8

  for orientation <- @orientations do
    test "orient policy controls no-geometry EXIF #{orientation} requests" do
      orientation = unquote(orientation)
      base = marked_image()

      auto = image("/orient=auto/format=png/src/images/x.jpg", oriented(base, orientation))
      displayed = image("/format=png/src/images/x.jpg", twin(base, orientation))

      none = image("/orient=none/format=png/src/images/x.jpg", oriented(base, orientation))
      stored = image("/format=png/src/images/x.jpg", oriented(base, 1))

      assert_pixel_close(auto, displayed, orientation, :auto)
      assert_pixel_close(none, stored, orientation, :none)
    end
  end

  test "user rotation still applies when EXIF orientation is disabled" do
    base = marked_image()

    none_rotated =
      image(
        "/orient=none/rotate=90/format=png/src/images/x.jpg",
        oriented(base, 6)
      )

    stored_rotated =
      image(
        "/rotate=90/format=png/src/images/x.jpg",
        oriented(base, 1)
      )

    assert_pixel_close(none_rotated, stored_rotated, 6, :none_with_user_rotation)
  end

  test "orient=none with retained metadata normalizes the output orientation tag" do
    base = marked_image_with_metadata()

    none =
      image(
        "/orient=none/meta=keep/format=jpeg/src/images/x.jpg",
        oriented(base, 6)
      )

    stored =
      image(
        "/orient=none/meta=keep/format=jpeg/src/images/x.jpg",
        oriented(base, 1)
      )

    assert_pixel_close(none, stored, 6, :none_with_metadata)

    assert VipsImage.header_value(none, "orientation") in [
             {:ok, 1},
             {:error, "No such field"}
           ]

    assert {:ok, %{image_description: "Orientation metadata sentinel"}} = Image.exif(none)
  end

  test "orient=auto with retained metadata normalizes the output orientation tag" do
    base = marked_image()
    auto = image("/orient=auto/meta=keep/format=jpeg/src/images/x.jpg", oriented(base, 6))
    displayed = image("/meta=keep/format=jpeg/src/images/x.jpg", twin(base, 6))

    assert_pixel_close(auto, displayed, 6, :auto_with_metadata)

    assert VipsImage.header_value(auto, "orientation") in [
             {:ok, 1},
             {:error, "No such field"}
           ]
  end

  test "EXIF flush and metadata cleanup preserve corrupt-tail decode classification" do
    body =
      "priv/static/images/beach.jpg"
      |> Image.open!()
      |> Image.set_orientation!(6)
      |> Image.write!(:memory, suffix: ".jpg")
      |> corrupt_tail()

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end

    for options <- ["orient=none/meta=keep", "orient=auto"] do
      response = request("/#{options}/format=jpeg/src/images/x.jpg", origin)

      assert response.status == 415
      assert response.resp_body == "source response is not a supported image"
    end
  end

  test "orient=none trim=auto chooses the stored-frame top-left background" do
    base = trim_frame()

    none =
      image(
        "/orient=none/trim=auto/format=png/src/images/x.jpg",
        oriented(base, 6)
      )

    stored = image("/trim=auto/format=png/src/images/x.jpg", oriented(base, 1))
    auto = image("/orient=auto/trim=auto/format=png/src/images/x.jpg", oriented(base, 6))

    assert_pixel_close(none, stored, 6, :none_trim)
    refute PixelCompare.same_dims?(none, auto)
  end

  test "blurhash uses the request orientation policy" do
    base = marked_image()
    origin = oriented(base, 6)

    default = request("/output=blurhash/src/images/x.jpg", origin)
    explicit_auto = request("/orient=auto/output=blurhash/src/images/x.jpg", origin)
    none = request("/orient=none/output=blurhash/src/images/x.jpg", origin)
    stored = request("/output=blurhash/src/images/x.jpg", oriented(base, 1))

    assert default.status == 200
    assert explicit_auto.status == 200
    assert none.status == 200
    assert stored.status == 200

    assert default.resp_body == explicit_auto.resp_body
    assert none.resp_body == stored.resp_body
    refute none.resp_body == explicit_auto.resp_body
  end

  test "invalid orient is rejected before source access" do
    config =
      api_config({CountingOriginImage, test_pid: self()})

    response =
      conn(:get, "/orient=sideways/format=png/src/images/x.jpg")
      |> ImagePipe.Plug.call(config)

    assert response.status == 400
    refute_received :origin_fetch
  end

  test "horizontal flip buffers its result before the delivery clamp" do
    body = marked_image()

    {response, dimensions} =
      observed_request("/flip=h/w=400/enlarge/format=png/src/image", body, max_result_width: 64)

    assert response.status == 200
    assert dimensions == [{400, 240}]

    expected =
      body
      |> Image.from_binary!()
      |> Image.resize!(10.0)
      |> Image.flip!(:horizontal)
      |> Image.resize!(64 / 400)

    assert_pixels_equal(response, expected)
  end

  test "rotation groups buffer each display frame while preserving resample order" do
    body = marked_image()

    {response, dimensions} =
      observed_request(
        "/rotate=90/w=120/enlarge/-/rotate=90/w=60/format=png/src/image",
        body
      )

    assert response.status == 200
    assert dimensions == [{120, 200}, {60, 36}]

    expected =
      body
      |> Image.from_binary!()
      |> Image.resize!(5.0)
      |> Image.rotate!(90)
      |> Image.resize!(0.3)
      |> Image.rotate!(90)

    assert_pixels_equal(response, expected)
  end

  test "horizontal orientation rejects corrupt pixels before delivery" do
    body = File.read!("priv/static/images/beach.jpg") |> corrupt_tail()

    for options <- ["flip=h", "flip=h/meta=keep", "rotate=90/-/flip=h"] do
      {response, _dimensions} =
        observed_request("/#{options}/w=100/format=png/src/image", body)

      assert response.status == 415
      assert response.state == :sent
      assert response.resp_body == "source response is not a supported image"
    end
  end

  defp observed_request(path, body, extra \\ []) do
    prefix = [__MODULE__, :materialization]
    event = prefix ++ [:transform, :materialize, :stop]
    ref = make_ref()
    pid = self()

    :ok =
      :telemetry.attach(
        ref,
        event,
        fn _event, _measurements, metadata, _config ->
          send(pid, {ref, metadata[:dims]})
        end,
        nil
      )

    origin = fn conn -> Plug.Conn.send_resp(conn, 200, body) end
    config = api_config(origin) |> Keyword.merge(extra) |> Keyword.put(:telemetry_prefix, prefix)

    try do
      response = conn(:get, path) |> ImagePipe.Plug.call(config)
      {response, materialization_dimensions(ref)}
    after
      :telemetry.detach(ref)
    end
  end

  defp materialization_dimensions(ref) do
    receive do
      {^ref, dimensions} -> [dimensions | materialization_dimensions(ref)]
    after
      0 -> []
    end
  end

  defp assert_pixels_equal(response, expected) do
    actual = Image.from_binary!(response.resp_body)
    assert Image.shape(actual) == Image.shape(expected)
    assert VipsImage.write_to_binary(actual) == VipsImage.write_to_binary(expected)
  end

  defp assert_pixel_close(actual, expected, orientation, policy) do
    assert PixelCompare.same_dims?(actual, expected),
           "EXIF #{orientation} #{policy}: dimensions differ, " <>
             "#{inspect(PixelCompare.dims(actual))} != #{inspect(PixelCompare.dims(expected))}"

    fraction = PixelCompare.fraction_over(actual, expected, 1)

    assert fraction == 0.0,
           "EXIF #{orientation} #{policy}: #{fraction * 100}% of samples differ"
  end

  defp image(path, origin) do
    response = request(path, origin)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp request(path, origin) do
    conn(:get, path)
    |> ImagePipe.Plug.call(api_config(origin))
  end

  defp api_config(origin) do
    ImagePipe.Plug.init(
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    )
  end

  defp oriented(base, orientation), do: {OrientedFrameOrigin, {base, orientation}}
  defp twin(base, orientation), do: {Orientation1TwinOrigin, {base, orientation}}

  defp marked_image do
    40
    |> Image.new!(24, color: [10, 20, 30])
    |> Image.Draw.rect!(0, 0, 11, 7, color: [240, 40, 40])
    |> Image.Draw.rect!(23, 3, 14, 9, color: [40, 240, 40])
    |> Image.Draw.rect!(4, 15, 20, 6, color: [40, 40, 240])
    |> Image.write!(:memory, suffix: ".png")
  end

  defp marked_image_with_metadata do
    image = marked_image() |> Image.open!(access: :random)

    {:ok, tagged} =
      VipsImage.mutate(image, fn mutable ->
        VipsMutableImage.set(
          mutable,
          "exif-ifd0-ImageDescription",
          :gchararray,
          "Orientation metadata sentinel"
        )

        :ok
      end)

    Image.write!(tagged, :memory, suffix: ".jpg")
  end

  defp corrupt_tail(body) do
    prefix_size = max(byte_size(body) - 64, 1)
    binary_part(body, 0, prefix_size) <> :binary.copy(<<0>>, 64)
  end

  defp trim_frame do
    60
    |> Image.new!(40, color: [20, 20, 20])
    |> Image.Draw.rect!(0, 0, 60, 8, color: [240, 20, 20])
    |> Image.Draw.rect!(0, 0, 6, 40, color: [240, 20, 20])
    |> Image.Draw.rect!(0, 30, 60, 10, color: [20, 240, 20])
    |> Image.write!(:memory, suffix: ".png")
  end
end

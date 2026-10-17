defmodule ImagePipe.API.DetectionFrameWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.BodyOrigin
  alias ImagePipe.Test.DetectorFixtures.SmallFaceDetector
  alias ImagePipe.Test.OrientedFrameOrigin

  # 2400x1600: gray, with the right 40% blue. The detector finds a face in the
  # blue part only in a frame at least 640 pixels on the long edge.
  defp scene do
    Image.new!(2400, 1600, color: [128, 128, 128])
    |> Image.compose!(Image.new!(960, 1600, color: [0, 0, 255]), x: 1440, y: 0)
  end

  test "a small cover crop detects on a frame at the detection floor" do
    for {suffix, mime} <- [{".jpg", "image/jpeg"}, {".webp", "image/webp"}, {".png", "image/png"}] do
      body = Image.write!(scene(), :memory, suffix: suffix)
      image = image!("w=64/h=64/fit=cover/detect=face", mount({BodyOrigin, {body, mime}}))

      assert_receive {:detect_frame, width, height, _orientation}
      assert max(width, height) in 640..1280, "#{suffix}: detected on #{width}x#{height}"
      assert {Image.width(image), Image.height(image)} == {64, 64}
      assert_blue(image, suffix)
    end
  end

  test "a cover crop at or above the detection floor detects on the resized frame" do
    body = Image.write!(scene(), :memory, suffix: ".png")
    image = image!("w=900/h=900/fit=cover/detect=face", mount({BodyOrigin, {body, "image/png"}}))

    assert_receive {:detect_frame, 1350, 900, _orientation}
    assert {Image.width(image), Image.height(image)} == {900, 900}
  end

  test "face assistance detects on a frame at the detection floor" do
    body = Image.write!(scene(), :memory, suffix: ".png")

    image =
      image!("w=64/h=64/fit=cover/anchor=smart-face", mount({BodyOrigin, {body, "image/png"}}))

    assert_receive {:detect_frame, width, height, _orientation}
    assert max(width, height) in 640..1280
    assert {Image.width(image), Image.height(image)} == {64, 64}
  end

  test "an EXIF-rotated source detects on the display frame at the detection floor" do
    # Orientation 6 displays the stored frame turned a quarter clockwise.
    storage = scene() |> Image.rotate!(270) |> Image.write!(:memory, suffix: ".png")
    image = image!("w=64/h=64/fit=cover/detect=face", mount({OrientedFrameOrigin, {storage, 6}}))

    assert_receive {:detect_frame, width, height, orientation}
    assert width > height
    assert width in 640..1280
    assert orientation in [nil, 1]
    assert_blue(image, "EXIF 6")
  end

  # The crop is centered on the face, so the middle of the output is blue.
  defp assert_blue(image, label) do
    [red, green, blue | _] = Image.get_pixel!(image, 32, 32)

    assert blue > 200 and red < 60 and green < 60,
           "#{label}: center pixel #{inspect([red, green, blue])}"
  end

  defp image!(options, config) do
    response = conn(:get, "/#{options}/format=png/src/scene") |> ImagePipe.Plug.call(config)
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp mount(origin) do
    ImagePipe.Plug.init(
      sources: [
        path: [
          adapter: RootHTTPAdapter,
          match: :path,
          options: [root_url: "http://origin.test", req_options: [plug: origin]]
        ]
      ],
      detector: SmallFaceDetector,
      max_body_bytes: 20_000_000,
      max_input_pixels: 40_000_000
    )
  end
end

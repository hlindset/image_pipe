defmodule ImagePipe.API.ObjectCropWireTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.DetectorFixtures.CornerObjectDetector
  alias ImagePipe.Test.DetectorFixtures.PartialDetector
  alias ImagePipe.Test.DetectorFixtures.RecordingDetector
  alias ImagePipe.Test.DetectorFixtures.UnavailableDetector
  alias ImagePipe.Test.DetectorFixtures.VerCompositeV1V1
  alias ImagePipe.Test.DetectorFixtures.VerCompositeV1V2
  alias ImagePipe.Test.DetectorFixtures.VerCompositeV2V1
  alias ImagePipe.Test.DetectorFixtures.WeightedSceneDetector
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias Vix.Vips.Image, as: VipsImage

  test "object selection changes crop pixels from center and attention" do
    opts = mount(detector: CornerObjectDetector)
    detected = response("w=50/h=50/fit=cover/detect=car", opts) |> image()
    centered = response("w=50/h=50/fit=cover/anchor=center", opts) |> image()
    attention = response("w=50/h=50/fit=cover/anchor=smart", opts) |> image()

    assert dimensions(detected) == {50, 50}
    refute pixels(detected) == pixels(centered)
    refute pixels(detected) == pixels(attention)
  end

  test "weights and selected classes affect both guided and cover crops" do
    opts = mount(detector: WeightedSceneDetector)

    for geometry <- ["crop=2000,2000", "w=2000/h=2000/fit=cover"] do
      uniform = response("#{geometry}/detect=all", opts) |> image()
      boosted = response("#{geometry}/detect=all,face:8", opts) |> image()
      face = response("#{geometry}/detect=face", opts) |> image()
      weighted_face = response("#{geometry}/detect=face:3", opts) |> image()

      refute pixels(boosted) == pixels(uniform)
      assert pixels(weighted_face) == pixels(face)
      refute pixels(face) == pixels(uniform)
    end
  end

  test "explicit face-assisted attention changes pixels while plain smart stays detector-free" do
    opts = mount(detector: WeightedSceneDetector)
    plain = response("w=2000/h=2000/fit=cover/anchor=smart", opts) |> image()
    assisted = response("w=2000/h=2000/fit=cover/anchor=smart-face", opts) |> image()
    refute pixels(assisted) == pixels(plain)
  end

  test "strict unavailable detection rejects before source resolution and cache access" do
    prefix = [:api_detection_gate]
    event = prefix ++ [:source, :resolve, :start]
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, event, &__MODULE__.forward_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    opts =
      mount(
        detector: UnavailableDetector,
        detector_required: true,
        cache: {CacheProbe, []},
        telemetry_prefix: prefix
      )

    assert response("crop=20,20/detect=face", opts).status == 422
    refute_received {:source_event, ^event}
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _body}
  end

  test "optional detection and strict face-assisted smart crop fall back to attention" do
    for {guide, required?} <- [{"detect=face", false}, {"anchor=smart-face", true}] do
      opts = mount(detector: UnavailableDetector, detector_required: required?)
      fallback = response("w=50/h=50/fit=cover/#{guide}", opts) |> image()
      plain = response("w=50/h=50/fit=cover/anchor=smart", opts) |> image()
      assert pixels(fallback) == pixels(plain)
    end
  end

  test "strict availability follows the requested classes" do
    opts = mount(detector: PartialDetector, detector_required: true)
    assert response("crop=50,50/detect=face", opts).status == 200
    assert_received :origin_fetch
    assert response("crop=50,50/detect=unicorn", opts).status == 200
    assert_received :origin_fetch
    assert response("crop=50,50/detect=car", opts).status == 422
    refute_received :origin_fetch
  end

  test "detectors receive display or storage pixels according to orientation policy" do
    body = Image.new!(40, 80, color: :red) |> Image.write!(:memory, suffix: ".png")
    opts = mount(detector: RecordingDetector, origin: {OrientedFrameOrigin, {body, 6}})

    assert response("orient=auto/crop=30,30/detect=face", opts).status == 200
    assert_receive {:detect_input, 80, 40, ["face"]}
    assert response("orient=none/crop=30,30/detect=face", opts).status == 200
    assert_receive {:detect_input, 40, 80, ["face"]}
  end

  test "equivalent class orders and weight spellings share identity" do
    opts = mount(detector: WeightedSceneDetector)
    first = response("crop=2000,2000/detect=person,face:3", opts)
    second = response("crop=2000,2000/detect=face:3.0,person:1.0", opts)
    assert first.status == 200
    assert second.status == 200
    assert [_etag] = get_resp_header(first, "etag")
    assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
    assert first.resp_body == second.resp_body
  end

  test "cache and ETag identity include only relevant detector models across groups" do
    for {options, face_changes?, object_changes?} <- [
          {"crop=80,80/detect=car", false, true},
          {"crop=80,80/detect=face", true, false},
          {"crop=80,80/detect=all", true, true},
          {"crop=80,80/anchor=smart-face", true, false},
          {"crop=80,80/detect=car/then/crop=40,40/anchor=smart-face", true, true},
          {"crop=80,80/anchor=smart", false, false}
        ] do
      {key, etag} = identities(options, VerCompositeV1V1)
      {face_key, face_etag} = identities(options, VerCompositeV2V1)
      {object_key, object_etag} = identities(options, VerCompositeV1V2)
      assert key != face_key == face_changes?
      assert etag != face_etag == face_changes?
      assert key != object_key == object_changes?
      assert etag != object_etag == object_changes?
    end
  end

  test "inert or malformed detection guides reject before source access" do
    opts = mount(detector: RecordingDetector)

    for options <- [
          "detect=face",
          "anchor=smart-face",
          "crop=20,20/detect=face/anchor=center",
          "crop=20,20/detect=face/focus=0.5,0.5",
          "crop=20,20/detect=face:0",
          "crop=20,20/detect=face:1000001",
          "crop=20,20/anchor=smart-face/anchor-offset=1,2"
        ] do
      assert response(options, opts).status == 400
      refute_received :origin_fetch
    end
  end

  def forward_event(event, _measurements, _metadata, pid), do: send(pid, {:source_event, event})

  defp identities(options, detector) do
    response = response(options, mount(detector: detector, cache: {CacheProbe, []}))
    assert response.status == 200
    assert [etag] = get_resp_header(response, "etag")
    assert_receive {:cache_lookup, key}
    assert_receive {:cache_put, _key, _body}
    {key.hash, etag}
  end

  defp response(options, config),
    do: conn(:get, "/#{options}/format=png/src/beach.jpg") |> ImagePipe.Plug.call(config)

  defp image(response) do
    assert response.status == 200
    Image.from_binary!(response.resp_body)
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
  defp pixels(image), do: VipsImage.write_to_binary(image)

  defp mount(overrides) do
    {origin, overrides} = Keyword.pop_lazy(overrides, :origin, &default_origin/0)

    [
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           byte_identity: :strong,
           internal_cache: :enabled,
           req_options: [plug: origin]}
      ],
      http_cache: [mode: :enabled],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end

  defp default_origin do
    body = File.read!("priv/static/images/beach.jpg")
    pid = self()

    fn conn ->
      send(pid, :origin_fetch)
      conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end
  end
end

defmodule ImagePipe.Transform.ExecutorDecodeOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Test.DetectorFixtures.ColdFaceDetector
  alias ImagePipe.Test.DetectorFixtures.CornerObjectDetector
  alias ImagePipe.Test.DetectorFixtures.ObjectOnlyDetector
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  @formats [:jpeg, :webp, :png]

  defp request!(options) do
    path = "/" <> options <> if(options == "", do: "", else: "/") <> "src/test"
    {:ok, lexed} = Path.extract(path, "")
    {:ok, request} = Parser.parse(lexed, [])
    request
  end

  # `display` is the frame after EXIF auto-orient; a quarter-turn EXIF tag with
  # auto-rotate on swaps it against `storage`.
  defp geometry(storage, display, format, pending \\ %PendingOrientation{}) do
    %SourceGeometry{
      storage_dimensions: storage,
      display_dimensions: display,
      pending_orientation: pending,
      source_format: format
    }
  end

  defp options(request_options, geometry, opts \\ []),
    do: Executor.decode_options(request!(request_options), geometry, opts)

  defp refute_shrink(opts) do
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "a crop and its resize produce format-specific load options" do
    # The 1600x1200 crop feeds a 400x300 resize: min(1600/400, 1200/300) = 4.
    plan = &options("region=0,0,1600,1200/w=400/h=300", geometry({3200, 2400}, {3200, 2400}, &1))

    assert plan.(:jpeg)[:shrink] == 4
    assert plan.(:webp)[:scale] == 0.25
    refute_shrink(plan.(:png))
  end

  test "a crop shrinks on load by at most an eighth of its short side" do
    jpeg = geometry({2000, 1600}, {2000, 1600}, :jpeg)
    webp = geometry({2000, 1600}, {2000, 1600}, :webp)

    refute_shrink(options("region=0,804,2000,8/w=50", jpeg))
    refute_shrink(options("crop=2000,8/w=50", jpeg))
    # 40 / 8 = 5, so JPEG takes its largest shrink under 5.
    assert options("region=0,800,2000,40/w=50", jpeg)[:shrink] == 4
    assert options("region=0,800,2000,40/w=50", webp)[:scale] == 0.2
    assert options("region=0,800,2000,100/w=50", jpeg)[:shrink] == 8
  end

  test "an SVG renders past its intrinsic size without enlarge" do
    svg = geometry({24, 24}, {24, 24}, :svg)

    assert options("w=480", svg)[:scale] == 20.0
    assert options("w=24/dpr=2", svg)[:scale] == 2.0
    assert options("region=0,0,12,12/w=120", svg)[:scale] == 10.0
    refute_shrink(options("w=480", geometry({24, 24}, {24, 24}, :png)))
  end

  test "a crop clamps to the display frame before choosing the shrink" do
    # The 4096x4096 region clamps to 4096x4000; covering 512x512 gives
    # min(4096/512, 4000/512) = 7.8125. The unclamped region would give 8.
    opts =
      options(
        "region=0,0,4096,4096/w=512/h=512/fit=cover",
        geometry({6000, 4000}, {6000, 4000}, :webp)
      )

    assert_in_delta opts[:scale], 512 / 4000, 1.0e-12
  end

  # An asymmetric 200x50 stretch target makes the frame's orientation decide
  # which axis governs: on 3200x800, min(3200/200, 800/50) = 16 (shrink 8); on
  # 800x3200, min(800/200, 3200/50) = 4 (shrink 4).
  @stretch "w=200/h=50/fit=stretch"

  test "an EXIF quarter turn swaps the shrink axes only when auto-rotation applies it" do
    exif_six = PendingOrientation.from_exif(6, true)

    assert options(@stretch, geometry({3200, 800}, {800, 3200}, :jpeg, exif_six))[:shrink] == 4
    assert options(@stretch, geometry({3200, 800}, {3200, 800}, :jpeg))[:shrink] == 8
  end

  test "a user quarter turn swaps the shrink axes when there is no EXIF turn" do
    geometry = geometry({3200, 800}, {3200, 800}, :jpeg)

    assert options("rotate=90/" <> @stretch, geometry)[:shrink] == 4
    assert options(@stretch, geometry)[:shrink] == 8
  end

  test "an EXIF quarter turn and a user quarter turn cancel to no swap" do
    # EXIF 6 (90) + rotate=90 = net 180, which does not transpose the axes.
    geometry = geometry({3200, 800}, {800, 3200}, :jpeg, PendingOrientation.from_exif(6, true))

    assert options("rotate=90/" <> @stretch, geometry)[:shrink] == 8
  end

  test "a trim disables shrink even when a resize target is present" do
    opts = options("trim=auto/w=400/h=300", geometry({3200, 2400}, {3200, 2400}, :jpeg))

    refute_shrink(opts)
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  test "a nearest-neighbour resize disables shrink, so the decode keeps source pixels" do
    for format <- @formats do
      refute_shrink(
        options("w=400/h=300/kernel=nearest", geometry({3200, 2400}, {3200, 2400}, format))
      )
    end
  end

  test "a filtering kernel keeps shrink" do
    plan = &options("w=400/h=300/kernel=" <> &1, geometry({3200, 2400}, {3200, 2400}, :jpeg))

    for kernel <- ~w(linear cubic mitchell lanczos2 lanczos3 mks2013 mks2021),
        do: assert(plan.(kernel)[:shrink] == 8)
  end

  test "only the first group's kernel decides the shrink" do
    geometry = geometry({3200, 2400}, {3200, 2400}, :jpeg)

    assert options("w=400/h=300/-/w=100/kernel=nearest", geometry)[:shrink] == 8
  end

  test "an SVG still renders at a nearest-neighbour resize target" do
    assert options("w=480/kernel=nearest", geometry({24, 24}, {24, 24}, :svg))[:scale] == 20.0
  end

  # --- Terminal-aware shrink (#377) ---

  test "the terminal reduction alone informs load shrink" do
    # output=blurhash with no resize: min(3200/32, 2400/32) = 75.
    assert options("output=blurhash", geometry({3200, 2400}, {3200, 2400}, :jpeg))[:shrink] == 8

    assert_in_delta options("output=blurhash", geometry({3200, 2400}, {3200, 2400}, :webp))[
                      :scale
                    ],
                    1 / 75,
                    1.0e-12
  end

  test "a resize target governs over the terminal reduction" do
    # min(3200/800, 2400/600) = 4, not the terminal's 75.
    opts = options("w=800/h=600/output=blurhash", geometry({3200, 2400}, {3200, 2400}, :jpeg))

    assert opts[:shrink] == 4
  end

  test "a request without a resize, crop, or placeholder produces no shrink or scale" do
    for format <- @formats do
      opts = options("", geometry({3200, 2400}, {3200, 2400}, format))

      refute_shrink(opts)
      assert opts[:access] == :sequential
      assert opts[:fail_on] == :error
    end
  end

  # --- Detection floor ---

  test "a detection guide keeps the decoded long edge at the detection floor" do
    # A 96x64 cover target alone gives 1600/64 = 25; the 640 floor caps it at
    # 2400/640 = 3.75.
    for guide <- ["detect=face", "anchor=smart-face"] do
      plan =
        &options("w=64/h=64/fit=cover/#{guide}", geometry({2400, 1600}, {2400, 1600}, &1),
          detector: CornerObjectDetector
        )

      assert plan.(:jpeg)[:shrink] == 2
      assert_in_delta plan.(:webp)[:scale], 1 / 3.75, 1.0e-12
      refute_shrink(plan.(:png))
    end
  end

  test "a detect crop's floor holds on the 2400x1600 frame it searches" do
    # The 1280x1280 crop for a 64x64 resize gives 20; the floor on the frame
    # caps it at 2400/640 = 3.75.
    opts =
      options("crop=1280,1280/detect=face/w=64/h=64", geometry({2400, 1600}, {2400, 1600}, :jpeg),
        detector: CornerObjectDetector
      )

    assert opts[:shrink] == 2
  end

  test "the detection floor holds on the whole frame a detect crop searches" do
    # The detector sees the 6000x4000 frame, so the floor allows 6000/640 =
    # 9.4. The 800x600 crop for a 200 wide resize gives 4.
    opts =
      options("crop=800,600/detect=face/w=200", geometry({6000, 4000}, {6000, 4000}, :jpeg),
        detector: CornerObjectDetector
      )

    assert opts[:shrink] == 4
  end

  test "a cover resize after a crop keeps the floor on the crop box it searches" do
    frame = geometry({6000, 4000}, {6000, 4000}, :jpeg)

    # Each cover crop detects on a 1000 or 800 wide box, so it decodes at
    # full size to keep 640 pixels.
    for request <- [
          "region=0,0,1000,1000/detect=face/w=64/h=48/fit=cover",
          "crop=800,600/detect=face/w=200/h=200/fit=cover"
        ] do
      refute options(request, frame, detector: CornerObjectDetector)[:shrink], request
    end

    covering =
      options(
        "crop=2400,1600/detect=face/w=64/h=64/fit=cover",
        geometry({2400, 1600}, {2400, 1600}, :jpeg),
        detector: CornerObjectDetector
      )

    assert covering[:shrink] == 2
  end

  test "a detect crop that covers the frame can't move, so it needs no floor" do
    opts =
      options("crop=2400,1600/detect=face/w=64", geometry({2400, 1600}, {2400, 1600}, :jpeg),
        detector: CornerObjectDetector
      )

    assert opts[:shrink] == 8
  end

  test "the detection floor needs a detector and a detection guide" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)

    assert options("w=64/h=64/fit=cover/detect=face", frame)[:shrink] == 8

    assert options("w=64/h=64/fit=cover/anchor=smart", frame, detector: CornerObjectDetector)[
             :shrink
           ] == 8
  end

  test "the detection floor needs a detector that can find the guide's classes" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)

    assert options("w=64/h=64/fit=cover/detect=face", frame, detector: ObjectOnlyDetector)[
             :shrink
           ] == 8

    assert options("w=64/h=64/fit=cover/detect=car,face", frame, detector: ObjectOnlyDetector)[
             :shrink
           ] == 2
  end

  test "a required detector that isn't ready keeps no floor for a smart-face crop" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)
    plan = &options("w=64/h=64/fit=cover/anchor=smart-face", frame, &1)

    # A required detector loads no models during a request, so the crop
    # falls back to attention.
    assert plan.(detector: ColdFaceDetector, detector_required: true)[:shrink] == 8
    assert plan.(detector: ColdFaceDetector)[:shrink] == 2
  end

  test "a cover resize whose target has the frame's shape crops nothing, so it needs no floor" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)
    opts = options("w=96/h=64/fit=cover/detect=face", frame, detector: CornerObjectDetector)

    assert opts[:shrink] == 8
  end

  test "the detection floor never shrinks a decode more than its target does" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)
    opts = options("w=1200/h=600/fit=cover/detect=face", frame, detector: CornerObjectDetector)

    assert opts[:shrink] == 2
  end

  test "the detection floor doesn't enlarge an SVG past its intrinsic size" do
    svg = geometry({100, 100}, {100, 100}, :svg)

    assert options("w=64/h=48/fit=cover/detect=face", svg, detector: CornerObjectDetector)[:scale] ==
             1.0

    assert options("w=320/h=240/fit=cover/detect=face", svg, detector: CornerObjectDetector)[
             :scale
           ] == 3.2
  end
end

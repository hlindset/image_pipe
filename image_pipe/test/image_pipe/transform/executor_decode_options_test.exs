defmodule ImagePipe.Transform.ExecutorDecodeOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
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
          detector?: true
        )

      assert plan.(:jpeg)[:shrink] == 2
      assert_in_delta plan.(:webp)[:scale], 1 / 3.75, 1.0e-12
      refute_shrink(plan.(:png))
    end
  end

  test "the detection floor applies to a detect crop's extent" do
    # The 1280x1280 crop for a 64x64 resize gives 20; the floor caps it at 2.
    opts =
      options("crop=1280,1280/detect=face/w=64/h=64", geometry({2400, 1600}, {2400, 1600}, :jpeg),
        detector?: true
      )

    assert opts[:shrink] == 2
  end

  test "the detection floor needs a detector and a detection guide" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)

    assert options("w=64/h=64/fit=cover/detect=face", frame)[:shrink] == 8
    assert options("w=64/h=64/fit=cover/anchor=smart", frame, detector?: true)[:shrink] == 8
  end

  test "the detection floor never shrinks a decode more than its target does" do
    frame = geometry({2400, 1600}, {2400, 1600}, :jpeg)
    opts = options("w=1200/h=800/fit=cover/detect=face", frame, detector?: true)

    assert opts[:shrink] == 2
  end

  test "the detection floor doesn't enlarge an SVG past its intrinsic size" do
    svg = geometry({100, 100}, {100, 100}, :svg)

    assert options("w=64/h=64/fit=cover/detect=face", svg, detector?: true)[:scale] == 1.0
    assert options("w=320/h=320/fit=cover/detect=face", svg, detector?: true)[:scale] == 3.2
  end
end

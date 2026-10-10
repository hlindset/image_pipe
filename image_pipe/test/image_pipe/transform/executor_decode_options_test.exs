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

  defp options(request_options, geometry),
    do: Executor.decode_options(request!(request_options), geometry)

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
end

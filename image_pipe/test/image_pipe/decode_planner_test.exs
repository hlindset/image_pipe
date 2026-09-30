defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.DecodePlanner.Request

  defp options(request, format, dims, exif_quarter_turn? \\ false, auto_rotate? \\ false) do
    DecodePlanner.open_options_for(
      request,
      format,
      dims,
      exif_quarter_turn?,
      auto_rotate?
    )
  end

  test "decode always opens sequentially with fail_on error" do
    for format <- [:jpeg, :webp, :png, :avif, :unknown] do
      opts = options(%Request{}, format, {3000, 2000})
      assert opts[:access] == :sequential
      assert opts[:fail_on] == :error
    end
  end

  test "JPEG shrink is the largest supported power of two within the load ratio" do
    request = %Request{resize_target: {400, nil}}

    assert options(request, :jpeg, {3200, 2400})[:shrink] == 8
    assert options(request, :jpeg, {3000, 2000})[:shrink] == 4
    assert options(request, :jpeg, {1000, 800})[:shrink] == 2

    opts = options(request, :jpeg, {600, 400})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "two-axis targets use the tighter ratio" do
    request = %Request{resize_target: {400, 600}}

    assert options(request, :jpeg, {3200, 2400})[:shrink] == 4
  end

  test "single-axis targets constrain only their own axis" do
    assert options(%Request{resize_target: {100, nil}}, :jpeg, {1600, 1200})[:shrink] == 8
    assert options(%Request{resize_target: {nil, 100}}, :jpeg, {1200, 1600})[:shrink] == 8
  end

  test "EXIF quarter turns swap shrink axes only when auto-rotation is enabled" do
    request = %Request{resize_target: {400, nil}}

    assert options(request, :jpeg, {3200, 800}, true, true)[:shrink] == 2
    assert options(request, :jpeg, {3200, 800}, true, false)[:shrink] == 8
    assert options(request, :jpeg, {3200, 800}, false, true)[:shrink] == 8
  end

  test "the user quarter-turn combines with EXIF by net orientation" do
    request = %Request{resize_target: {400, nil}, user_quarter_turn?: true}

    assert options(request, :jpeg, {3200, 800})[:shrink] == 2
    assert options(request, :jpeg, {3200, 800}, true, true)[:shrink] == 8
    assert options(request, :jpeg, {3200, 800}, true, false)[:shrink] == 2
  end

  test "WebP uses the exact fractional scale" do
    request = %Request{resize_target: {333 * 1.1, nil}}
    opts = options(request, :webp, {1600, 1200})

    assert_in_delta opts[:scale], 366.3 / 1600, 1.0e-12
    refute Keyword.has_key?(opts, :shrink)
  end

  test "WebP emits no load scale when the target is larger than the source" do
    opts = options(%Request{resize_target: {800, nil}}, :webp, {600, 400})

    refute Keyword.has_key?(opts, :scale)
    refute Keyword.has_key?(opts, :shrink)
  end

  test "DPR and zoom inflated targets prevent over-shrinking" do
    dpr = %Request{resize_target: {1332.0, nil}}
    assert options(dpr, :jpeg, {4000, 2667})[:shrink] == 2

    zoom = %Request{resize_target: {800.0, nil}}
    assert options(zoom, :jpeg, {4000, 2667})[:shrink] == 4
  end

  test "crop extent, rather than full source dimensions, feeds the resize ratio" do
    request = %Request{crop_extent: {1200, 1200}, resize_target: {400, 400}}

    assert options(request, :jpeg, {4000, 2667})[:shrink] == 2
  end

  test "a crop close to its resize target does not shrink" do
    request = %Request{crop_extent: {600, 600}, resize_target: {500, 500}}
    opts = options(request, :jpeg, {4000, 2667})

    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "a tile crop clamps to source extent before choosing JPEG shrink" do
    request = %Request{crop_extent: {4096, 4000}, resize_target: {512, 512}}
    opts = options(request, :jpeg, {6000, 4000})

    assert opts[:shrink] == 4
  end

  test "trim disables shrink even when a resize target is present" do
    request = %Request{trim?: true, resize_target: {100, 100}}
    opts = options(request, :jpeg, {800, 800})

    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "formats without load-time reduction ignore resize targets" do
    request = %Request{resize_target: {10, nil}}

    for format <- [:png, :heif, :avif, :some_unknown_format] do
      opts = options(request, format, {3000, 2000})
      refute Keyword.has_key?(opts, :shrink)
      refute Keyword.has_key?(opts, :scale)
    end
  end
end

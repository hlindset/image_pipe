defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.DecodePlanner

  defp refute_shrink(opts) do
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "decode always opens sequentially with fail_on error" do
    for format <- [:jpeg, :webp, :png, :avif, :unknown], target <- [nil, {400, nil}] do
      opts = DecodePlanner.open_options(format, {3000, 2000}, target)
      assert opts[:access] == :sequential
      assert opts[:fail_on] == :error
    end
  end

  test "JPEG shrink is the largest supported power of two within the load ratio" do
    assert DecodePlanner.open_options(:jpeg, {3200, 2400}, {400, nil})[:shrink] == 8
    assert DecodePlanner.open_options(:jpeg, {3000, 2000}, {400, nil})[:shrink] == 4
    assert DecodePlanner.open_options(:jpeg, {1000, 800}, {400, nil})[:shrink] == 2

    refute_shrink(DecodePlanner.open_options(:jpeg, {600, 400}, {400, nil}))
  end

  test "two-axis targets use the tighter ratio" do
    assert DecodePlanner.open_options(:jpeg, {3200, 2400}, {400, 600})[:shrink] == 4
  end

  test "single-axis targets constrain only their own axis" do
    assert DecodePlanner.open_options(:jpeg, {1600, 1200}, {100, nil})[:shrink] == 8
    assert DecodePlanner.open_options(:jpeg, {1200, 1600}, {nil, 100})[:shrink] == 8
  end

  test "WebP uses the exact fractional scale" do
    opts = DecodePlanner.open_options(:webp, {1600, 1200}, {333 * 1.1, nil})

    assert_in_delta opts[:scale], 366.3 / 1600, 1.0e-12
    refute Keyword.has_key?(opts, :shrink)
  end

  test "WebP emits no load scale when the target is larger than the source" do
    refute_shrink(DecodePlanner.open_options(:webp, {600, 400}, {800, nil}))
  end

  test "DPR and zoom inflated targets prevent over-shrinking" do
    assert DecodePlanner.open_options(:jpeg, {4000, 2667}, {1332.0, nil})[:shrink] == 2
    assert DecodePlanner.open_options(:jpeg, {4000, 2667}, {800.0, nil})[:shrink] == 4
  end

  test "an extent close to its resize target does not shrink" do
    refute_shrink(DecodePlanner.open_options(:jpeg, {600, 600}, {500, 500}))
  end

  test "no target means no shrink" do
    for format <- [:jpeg, :webp] do
      refute_shrink(DecodePlanner.open_options(format, {800, 800}, nil))
    end
  end

  test "formats without load-time reduction ignore resize targets" do
    for format <- [:png, :heif, :avif, :some_unknown_format] do
      refute_shrink(DecodePlanner.open_options(format, {3000, 2000}, {10, nil}))
    end
  end
end

defmodule ImagePipe.Output.JxlDistanceTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.JxlDistance
  alias Vix.Vips.Image, as: VixImage

  test "known points match libjxl mapping" do
    assert_in_delta JxlDistance.from_quality(100), 0.0, 1.0e-6
    assert_in_delta JxlDistance.from_quality(90), 1.0, 1.0e-6
    assert_in_delta JxlDistance.from_quality(80), 1.9, 1.0e-6
    assert_in_delta JxlDistance.from_quality(70), 2.8, 1.0e-6
  end

  test "monotone non-increasing in quality" do
    ds = Enum.map(1..100, &JxlDistance.from_quality/1)
    assert ds == Enum.sort(ds, :desc)
  end

  @tag :jxl
  test "drift guard: encode(Q=q) is byte-identical to encode(distance=from_quality(q))" do
    {:ok, img} = Image.new(96, 96, color: [40, 160, 90])

    for q <- [50, 70, 80, 90] do
      {:ok, by_q} = VixImage.write_to_buffer(img, ".jxl[Q=#{q}]")
      {:ok, by_d} = Encoder.encode_jxl_distance(img, JxlDistance.from_quality(q))

      assert by_q == by_d,
             "Q=#{q} diverged from distance=#{JxlDistance.from_quality(q)} — libjxl formula drift"
    end
  end
end

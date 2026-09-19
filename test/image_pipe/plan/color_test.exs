defmodule ImagePipe.Plan.ColorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Color

  test "constructs opaque sRGB color from integer channels" do
    assert {:ok,
            %Color{
              space: :srgb,
              channels: {255, 0, 16},
              alpha: {:ratio, 1, 1}
            }} = Color.rgb(255, 0, 16)
  end

  test "rejects non-byte RGB channels" do
    assert Color.rgb(-1, 0, 0) == {:error, {:invalid_color, [-1, 0, 0]}}
    assert Color.rgb(0, 256, 0) == {:error, {:invalid_color, [0, 256, 0]}}
    assert Color.rgb(0, 0, 1.5) == {:error, {:invalid_color, [0, 0, 1.5]}}
  end

  test "constructs opaque sRGB color from 3 and 6 digit RGB hex" do
    assert Color.rgb_hex("f0a") == Color.rgb(255, 0, 170)
    assert Color.rgb_hex("ff00aa") == Color.rgb(255, 0, 170)
    assert Color.rgb_hex("FF00AA") == Color.rgb(255, 0, 170)
  end

  test "rejects CSS color forms outside raw RGB hex" do
    assert Color.rgb_hex("#f0a") == {:error, {:invalid_color, ["#f0a"]}}
    assert Color.rgb_hex("f0a8") == {:error, {:invalid_color, ["f0a8"]}}
    assert Color.rgb_hex("red") == {:error, {:invalid_color, ["red"]}}
  end

  test "constructs sRGB color with canonical alpha ratio" do
    assert {:ok,
            %Color{
              space: :srgb,
              channels: {255, 0, 16},
              alpha: {:ratio, 1, 2}
            }} = Color.rgba(255, 0, 16, {:ratio, 2, 4})
  end

  test "rejects malformed alpha ratios" do
    assert Color.rgba(0, 0, 0, {:ratio, -1, 1}) ==
             {:error, {:invalid_color, [0, 0, 0, {:ratio, -1, 1}]}}

    assert Color.rgba(0, 0, 0, {:ratio, 2, 1}) ==
             {:error, {:invalid_color, [0, 0, 0, {:ratio, 2, 1}]}}
  end

  test "serializes deterministic cache key data without leaking Color structs" do
    assert {:ok, red} = Color.rgba(255, 0, 0, {:ratio, 1, 2})

    assert Color.key_data(red) == [
             space: :srgb,
             red: 255,
             green: 0,
             blue: 0,
             alpha: [unit: :ratio, numerator: 1, denominator: 2]
           ]

    refute inspect(Color.key_data(red)) =~ "Color.SRGB"
  end
end

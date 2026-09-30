defmodule ImagePipe.Output.ClampTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.Encoder

  describe "encoder_limit/1" do
    test "returns the WebP and AVIF hard dimension limits with unbounded pixels" do
      assert Encoder.encoder_limit(:webp) == %{max_dimension: 16_383, max_pixels: :infinity}
      assert Encoder.encoder_limit(:avif) == %{max_dimension: 16_384, max_pixels: :infinity}
    end

    test "returns the documented JPEG limit and unbounded PNG" do
      assert Encoder.encoder_limit(:jpeg) == %{max_dimension: 65_535, max_pixels: :infinity}
      assert Encoder.encoder_limit(:png) == %{max_dimension: :infinity, max_pixels: :infinity}
    end
  end

  describe "clamp/3" do
    alias ImagePipe.Output.Clamp

    @inf %{max_width: :infinity, max_height: :infinity, max_pixels: :infinity}

    defp image(width, height) do
      {:ok, image} = Image.new(width, height)
      image
    end

    defp limits(opts) do
      %{
        max_width: Keyword.get(opts, :max_width, :infinity),
        max_height: Keyword.get(opts, :max_height, :infinity),
        max_pixels: Keyword.get(opts, :max_pixels, :infinity)
      }
    end

    test "no-op (unchanged image, nil info) when within all caps" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 1000, max_height: 1000), [])
    end

    test "no-op for an all-:infinity limits map" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, @inf, [])
    end

    test "no-op when a cap exactly equals a dimension (no degenerate resize)" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 200, max_height: 50), [])
    end

    test "downscales linearly when the width cap binds" do
      img = image(200, 50)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_width: 100), [])

      assert Image.width(resized) == 100
      assert Image.height(resized) == 25
      assert info.source_dimensions == {200, 50}
      assert info.dimensions == {100, 25}
      assert info.limits == limits(max_width: 100)
      assert_in_delta info.scale, 0.5, 1.0e-6
    end

    test "downscales when the height cap binds" do
      img = image(50, 200)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_height: 100), [])

      assert Image.width(resized) == 25
      assert Image.height(resized) == 100
      assert info.dimensions == {25, 100}
    end

    test "respects asymmetric caps without over-shrinking (per-axis)" do
      # 8000x4000, caps w<=10000 (slack), h<=4000 (exactly met) -> no clamp.
      img = image(8000, 4000)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 10_000, max_height: 4000), [])
    end

    test "downscales on the pixel budget, preserving aspect, realized product <= cap" do
      # 2000x2000 = 4_000_000 px; cap 1_000_000 -> scale 0.5 -> 1000x1000.
      img = image(2000, 2000)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_pixels: 1_000_000), [])

      w = Image.width(resized)
      h = Image.height(resized)
      assert w * h <= 1_000_000
      assert_in_delta w / 2000, h / 2000, 1.0e-6
      assert info.dimensions == {w, h}
    end

    test "takes the most-aggressive scale when pixel and dimension caps disagree" do
      # 4000x1000 = 4_000_000 px. max_width 2000 -> dim scale 0.5 (-> 2000x500=1_000_000).
      # max_pixels 250_000 -> sqrt(250000/4e6)=0.25 (-> 1000x250=250_000). Pixels win.
      img = image(4000, 1000)

      assert {:ok, resized, _info} =
               Clamp.clamp(img, limits(max_width: 2000, max_pixels: 250_000), [])

      assert Image.width(resized) <= 2000
      assert Image.width(resized) * Image.height(resized) <= 250_000
    end

    test "keeps each axis >= 1px for an extreme aspect ratio with a tight cap" do
      img = image(40_000, 1)
      assert {:ok, resized, _info} = Clamp.clamp(img, limits(max_width: 100), [])

      assert Image.width(resized) <= 100
      assert Image.height(resized) >= 1
    end

    # Deterministic cover for the deep pixel verify-and-shrink loop — the exact
    # path the bounded loop, the `long - 1` floor, and the 1px floor exist for.
    # (Traced: ~8 and ~10 iterations respectively, both well under the bound.)
    test "pixel cap on an extreme aspect ratio converges and fits (deep loop, 1px floor)" do
      img = image(40_000, 1)
      assert {:ok, resized, _info} = Clamp.clamp(img, limits(max_pixels: 100), [])

      w = Image.width(resized)
      h = Image.height(resized)
      assert h >= 1
      assert w * h <= 100
    end

    test "pixel cap on a tall sliver converges and fits (deep loop)" do
      img = image(1, 6000)
      assert {:ok, resized, _info} = Clamp.clamp(img, limits(max_pixels: 1300), [])

      w = Image.width(resized)
      h = Image.height(resized)
      assert w >= 1
      assert w * h <= 1300
    end
  end

  describe "clamp/3 pixel ≤-cap property" do
    alias ImagePipe.Output.Clamp

    # Bias the generator toward the regimes that actually drive the pixel loop
    # deep: extreme aspect ratios (one axis tiny) and small pixel caps. A uniform
    # square generator almost never reaches the >1-iteration path (~72% no-op),
    # leaving the loop the test exists to protect essentially unexercised.
    defp dim_gen do
      StreamData.frequency([
        {3, StreamData.integer(1..6000)},
        {2, StreamData.integer(1..8)}
      ])
    end

    property "realized dims and pixel product never exceed the caps" do
      check all(
              w <- dim_gen(),
              h <- dim_gen(),
              max_w <- StreamData.integer(1..6000),
              max_h <- StreamData.integer(1..6000),
              max_px <-
                StreamData.frequency([
                  {2, StreamData.integer(64..5000)},
                  {1, StreamData.integer(5001..2_000_000)}
                ]),
              max_runs: 400
            ) do
        {:ok, image} = Image.new(w, h)
        lim = %{max_width: max_w, max_height: max_h, max_pixels: max_px}

        # A `{:error, {:encode, ...}}` here would mean the bounded loop exhausted
        # (non-termination within the bound) — the pattern-match failure surfaces it.
        assert {:ok, resized, _info} = Clamp.clamp(image, lim, [])
        rw = Image.width(resized)
        rh = Image.height(resized)

        assert rw >= 1 and rh >= 1
        assert rw <= max_w
        assert rh <= max_h
        assert rw * rh <= max_px
      end
    end
  end
end

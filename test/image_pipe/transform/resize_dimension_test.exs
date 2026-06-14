defmodule ImagePipe.Transform.ResizeDimensionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize

  # #199: imgproxy folds dpr into a single `imath.Scale` (round(source × scale))
  # rather than rounding the fit dimension and then multiplying by dpr. For
  # rs:fit:300:200/dpr:2 on 1600×1200 the fit binds height (scale 200/1200); the
  # derived width is round(1600 × 200/1200 × 2) = round(533.3) = 533, NOT
  # round(266.67) = 267 then ×2 = 534. The binding axis is round(200 × 2) = 400.
  test "fit folds dpr into a single round on the derived axis (#199)" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 300},
      height: {:pixels, 200},
      dpr: 2.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1600, source_height: 1200)

    assert result.requested_width == 533
    assert result.requested_height == 400
  end

  # #199 (dpr=1 facet): the single-scale fold also corrects the fit auto-axis at
  # dpr=1. fit:auto:200 with enlarge on a 100×109 source — verified against imgproxy
  # calcScale: poWidth=0 makes wshrink=hshrink=109/200, WScale=1/0.545=1.835, so
  # ScaledWidth=Scale(100,1.835)=183 and ScaledHeight=Scale(109,1.835)=200. The old
  # double-round (rounding the auto-derived width to 183 first, then re-deriving
  # height through fit_inside) landed height at 199.
  test "fit auto-axis single-rounds to the imgproxy-correct derived dimension (#199)" do
    operation = %Resize{mode: :fit, width: :auto, height: {:pixels, 200}, enlarge: true}

    result = Resize.resolve_dimensions(operation, source_width: 100, source_height: 109)

    assert result.requested_width == 183
    assert result.requested_height == 200
    assert result.intermediate_width == 183
    assert result.intermediate_height == 200
  end

  test "min width interacts with fit without zoom" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 1000)

    assert result.requested_width == 100
    assert result.requested_height == 100
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "zoom scales requested dimensions but not min constraints" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      zoom_x: 2.0,
      zoom_y: 2.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 1000)

    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "dpr scales requested dimensions and participates in min-limited scale" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      dpr: 2.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 1000)

    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 600
    assert result.intermediate_height == 600
  end

  test "zero dimensions with zoom do not enlarge raster sources when enlarge is false" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 0},
      height: {:pixels, 0},
      zoom_x: 2.0,
      zoom_y: 2.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 100, source_height: 50)

    assert result.requested_width == 200
    assert result.requested_height == 100
    assert result.intermediate_width == 100
    assert result.intermediate_height == 50
  end

  test "zero dimensions with dpr do not enlarge raster sources when enlarge is false" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 0},
      height: {:pixels, 0},
      dpr: 2.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 100, source_height: 50)

    assert result.effective_dpr == 1.0
    assert result.requested_width == 100
    assert result.requested_height == 50
    assert result.intermediate_width == 100
    assert result.intermediate_height == 50
  end

  test "force resize auto dimensions preserve source dimensions" do
    operation = %Resize{mode: :force, width: :auto, height: {:pixels, 200}}

    result = Resize.resolve_dimensions(operation, source_width: 640, source_height: 480)

    assert result.requested_width == 640
    assert result.requested_height == 200
    assert result.intermediate_width == 640
    assert result.intermediate_height == 200

    operation = %Resize{mode: :force, width: {:pixels, 300}, height: :auto}

    result = Resize.resolve_dimensions(operation, source_width: 640, source_height: 480)

    assert result.requested_width == 300
    assert result.requested_height == 480
    assert result.intermediate_width == 300
    assert result.intermediate_height == 480
  end

  test "force zero dimensions honor min dimensions even when enlarge is false" do
    operation = %Resize{
      mode: :force,
      width: :auto,
      height: :auto,
      min_width: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 100, source_height: 50)

    assert result.target_width == 300
    assert result.target_height == 150
    assert result.intermediate_width == 300
    assert result.intermediate_height == 150
  end

  test "min height interacts with fit as a scale constraint" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_height: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 500)

    assert result.requested_width == 100
    assert result.requested_height == 50
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fit min-dimensions expose a result box smaller than the upscaled intermediate (#194)" do
    # rs:fit:300:300/mw:280/mh:280 on a 4:3 source: fit lands 300x225, then mh:280
    # forces a uniform upscale to 373x280. The result box stays the literal requested
    # 300x300 (NOT the min-expanded 373x280), so PlanExecutor crops the intermediate
    # back to it (gravity center) — matching imgproxy's cropToResult to 300x280.
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_width: {:pixels, 280},
      min_height: {:pixels, 280},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1600, source_height: 1200)

    assert result.intermediate_width == 373
    assert result.intermediate_height == 280
    assert result.result_box_width == 300
    assert result.result_box_height == 300
    # the result box bites on the upscaled axis, trimming 373 -> 300 (width) while
    # the min-dimension axis (280) survives intact
    assert result.result_box_width < result.intermediate_width
    assert result.result_box_height > result.intermediate_height
  end

  test "fit without min-dimensions keeps the result box at or above the intermediate (no crop)" do
    # A plain fit scales inside the requested box, so the result box never bites and
    # the fit path stays a single resize.
    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 300}}

    result = Resize.resolve_dimensions(operation, source_width: 1600, source_height: 1200)

    assert result.intermediate_width == 300
    assert result.intermediate_height == 225
    assert result.result_box_width == 300
    assert result.result_box_height == 300
    refute result.result_box_width < result.intermediate_width
    refute result.result_box_height < result.intermediate_height
  end

  test "fill resolves intermediate dimensions to the cover resize box" do
    operation = %Resize{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints before resolving the cover resize box" do
    operation = %Resize{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_width: {:pixels, 500},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.target_width == 500
    assert result.target_height == 500
    assert result.intermediate_width == 1000
    assert result.intermediate_height == 500
  end

  test "fill expands target before resolving the cover resize box" do
    operation = %Resize{
      mode: :fill,
      width: {:pixels, 100},
      height: {:pixels, 100},
      min_width: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 500)

    assert result.target_width == 300
    assert result.target_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill-down expands target before resolving the cover resize box" do
    operation = %Resize{
      mode: :fill_down,
      width: {:pixels, 100},
      height: {:pixels, 100},
      min_width: {:pixels, 300},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 1000, source_height: 500)

    assert result.target_width == 300
    assert result.target_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints before cover for the opposite aspect ratio" do
    operation = %Resize{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_height: {:pixels, 500},
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 500, source_height: 1000)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.target_width == 500
    assert result.target_height == 500
    assert result.intermediate_width == 500
    assert result.intermediate_height == 1000
  end

  test "effective dpr clamps below requested dpr for small non-vector sources when enlarge is false" do
    operation = %Resize{
      mode: :fit,
      width: {:pixels, 500},
      height: :auto,
      dpr: 3.0,
      enlarge: false
    }

    result = Resize.resolve_dimensions(operation, source_width: 800, source_height: 800)

    assert result.effective_dpr == 1.6
    assert result.requested_width == 800
    assert result.requested_height == 800
    assert result.intermediate_width == 800
    assert result.intermediate_height == 800
  end

  test "percent width resolves against the running source width" do
    operation = %Resize{mode: :fit, width: {:percent, 50}, height: :auto, enlarge: true}

    result = Resize.resolve_dimensions(operation, source_width: 340, source_height: 200)

    assert result.intermediate_width == 170
  end

  test "scale width resolves against the running source width" do
    operation = %Resize{mode: :fit, width: {:scale, 0.25}, height: :auto, enlarge: true}

    result = Resize.resolve_dimensions(operation, source_width: 400, source_height: 300)

    assert result.intermediate_width == 100
  end

  describe "max bounds" do
    # max (no ^): :fit auto/auto, deny enlarge. Ceiling larger than source -> source.
    test "max with ceiling larger than source clamps to source (no upscale)" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: false,
        max_width: 10_000,
        max_height: 10_000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 6000
      assert r.intermediate_height == 4000
    end

    # ^max: :fit auto/auto, enlarge. Ceiling larger than source -> grow to box.
    test "^max grows to the ceiling box (width-binding)" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: true,
        max_width: 10_000,
        max_height: 10_000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 10_000
      assert r.intermediate_height == 6667
    end

    # ^max with ceiling smaller than source -> downscale to box (no upscale needed).
    test "^max with sub-source ceiling downscales to the box" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: true,
        max_width: 2000,
        max_height: 2000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height == 1333
    end

    # max with sub-source ceiling -> clamp down.
    test "max clamps down to a sub-source ceiling" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: false,
        max_width: 2000,
        max_height: 2000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height == 1333
    end

    # Explicit width (no ^) exceeding maxWidth -> clamped down. Mode :fit, width {:pixels,4000}.
    test "explicit width exceeding maxWidth is clamped down" do
      op = %Resize{
        mode: :fit,
        width: {:pixels, 4000},
        height: :auto,
        enlarge: false,
        max_width: 2000,
        max_height: 2000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 2000
      assert r.intermediate_height <= 2000
    end

    # maxArea-only ^max upscales until area ~= max_area, and never exceeds it.
    test "maxArea-only ^max scales to the area ceiling without exceeding it" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: true,
        max_area: 50_000_000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width * r.intermediate_height <= 50_000_000
      # close to the ceiling (within one row/col of pixels)
      assert r.intermediate_width * r.intermediate_height >= 50_000_000 - 6000 * 2
    end

    # maxArea cap on a large image never exceeds the area MUST.
    test "maxArea caps area and never exceeds it" do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: false,
        max_area: 2_000_000
      }

      r = Resize.resolve_dimensions(op, source_width: 6000, source_height: 4000)
      assert r.intermediate_width * r.intermediate_height <= 2_000_000
    end

    # All-nil bounds are a byte-identical no-op vs. the same op without bound fields.
    test "all-nil bounds are a no-op" do
      bounded = %Resize{mode: :fit, width: {:pixels, 800}, height: :auto, enlarge: false}
      r = Resize.resolve_dimensions(bounded, source_width: 6000, source_height: 4000)
      assert r.intermediate_width == 800
    end
  end
end

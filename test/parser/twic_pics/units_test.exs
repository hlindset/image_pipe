defmodule ImagePipe.Parser.TwicPics.UnitsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Units

  describe "dimension_length/1 (>0)" do
    test "pixels, percent, scale" do
      assert Units.dimension_length("100") == {:ok, {:px, 100}}
      assert Units.dimension_length("50p") == {:ok, {:ratio, 1, 2}}
      assert Units.dimension_length("0.5s") == {:ok, {:ratio, 1, 2}}
      assert Units.dimension_length("0") == {:error, {:invalid_length, "0"}}
      assert Units.dimension_length("0p") == {:error, {:invalid_length, "0p"}}
    end

    test "px is not a TwicPics length unit (only p and s)" do
      # TwicPics has no `px` unit — pixels are bare. A standalone `250px` token
      # is invalid as a length; the `px` mixing case (`10px150`) is handled at
      # the Size level by splitting on `x` first (see size/1 below).
      assert {:error, _} = Units.dimension_length("250px")
    end

    test "percent and scale fractions" do
      assert Units.dimension_length("4.5p") == {:ok, {:ratio, 9, 200}}
    end

    test "rejects malformed" do
      assert {:error, _} = Units.dimension_length("abc")
      assert {:error, _} = Units.dimension_length("-3")
    end
  end

  describe "position_length/1 (>=0)" do
    test "allows zero pixels and zero percent" do
      assert Units.position_length("0") == {:ok, {:px, 0}}
      assert Units.position_length("0p") == {:ok, {:ratio, 0, 1}}
      assert Units.position_length("50p") == {:ok, {:ratio, 1, 2}}
      assert Units.position_length("-1") == {:error, {:invalid_length, "-1"}}
    end
  end

  describe "coordinates/1 uses position lengths" do
    test "zero-based origin" do
      assert Units.coordinates("0x0") == {:ok, {{:px, 0}, {:px, 0}}}
    end
  end

  describe "size/1 (resize/cover/contain/inside)" do
    test "WxH, single dim (auto), and dash-auto" do
      assert Units.size("250x100") == {:ok, {{:px, 250}, {:px, 100}}}
      assert Units.size("250") == {:ok, {{:px, 250}, :auto}}
      assert Units.size("-x100") == {:ok, {:auto, {:px, 100}}}
      assert Units.size("250x-") == {:ok, {{:px, 250}, :auto}}
    end

    test "mixed units: `10px150` is 10 percent by 150 pixels (split on x first)" do
      # Per the TwicPics docs, `10px150` is a Size mixing a percent width (`10p`)
      # with a pixel height (`150`) — NOT `10px` (there is no `px` unit).
      assert Units.size("10px150") == {:ok, {{:ratio, 1, 10}, {:px, 150}}}
      assert Units.size("250px") == {:ok, {{:ratio, 5, 2}, :auto}}
    end
  end

  describe "crop_size/1" do
    test "omitted dimension is the full axis (1s), not aspect auto" do
      assert Units.crop_size("320") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("320x-") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("-x240") == {:ok, {:full_axis, {:px, 240}}}
    end
  end

  describe "ratio/1" do
    test "integer ratios" do
      assert Units.ratio("16:9") == {:ok, {:ratio, 16, 9}}
      assert Units.ratio("2:4") == {:ok, {:ratio, 1, 2}}
    end

    test "decimal ratios reduce to an integer ratio (exact, no float rounding)" do
      assert Units.ratio("1.5:2") == {:ok, {:ratio, 3, 4}}
      assert Units.ratio("1.5:2.25") == {:ok, {:ratio, 2, 3}}
      assert Units.ratio("0.5:2") == {:ok, {:ratio, 1, 4}}
      assert Units.ratio("1.05:2.1") == {:ok, {:ratio, 1, 2}}
    end

    test "rejects non-positive and malformed" do
      assert {:error, _} = Units.ratio("0:9")
      assert {:error, _} = Units.ratio("0.0:9")
      assert {:error, _} = Units.ratio("-1.5:2")
      assert {:error, _} = Units.ratio("1.5.2:2")
      assert {:error, _} = Units.ratio("1.5")
      assert {:error, _} = Units.ratio("a:2")
    end
  end

  describe "coordinates/1" do
    test "two lengths" do
      assert Units.coordinates("20x50") == {:ok, {{:px, 20}, {:px, 50}}}
    end
  end

  describe "parenthesized arithmetic in numbers" do
    test "constant folding to an exact pixel measure" do
      assert Units.dimension_length("(100/2)") == {:ok, {:px, 50}}
      assert Units.dimension_length("(700/2)") == {:ok, {:px, 350}}
    end

    test "nesting and operator precedence (expression must be parenthesized)" do
      assert Units.dimension_length("(100/(4/2))") == {:ok, {:px, 50}}
      assert Units.dimension_length("(5*(7+2)/3)") == {:ok, {:px, 15}}
    end

    test "a bare top-level operator is rejected (TwicPics requires outer parens)" do
      # Live TwicPics 404s `resize=5*3`; only `(5*3)` is accepted.
      assert {:error, _} = Units.dimension_length("5*3")
      assert {:error, _} = Units.dimension_length("2+3")
      assert {:error, _} = Units.dimension_length("10-3")
      assert Units.dimension_length("(5*3)") == {:ok, {:px, 15}}
    end

    test "arithmetic feeds the relative-unit path exactly (no float rounding)" do
      assert Units.dimension_length("(1/2)s") == {:ok, {:ratio, 1, 2}}
      assert Units.dimension_length("(1/3)s") == {:ok, {:ratio, 1, 3}}
      assert Units.dimension_length("(1/3)p") == {:ok, {:ratio, 1, 300}}
      assert Units.dimension_length("(100/2)p") == {:ok, {:ratio, 1, 2}}
    end

    test "unary plus inside parens is identity (TwicPics accepts it)" do
      # Live TwicPics: (+5)->5, (2*+3)->6, (1++2)->3 ; symmetric to unary minus.
      assert Units.dimension_length("(+5)") == {:ok, {:px, 5}}
      assert Units.dimension_length("(2*+3)") == {:ok, {:px, 6}}
      assert Units.dimension_length("(1++2)") == {:ok, {:px, 3}}
    end

    test "rejects malformed and division by zero" do
      assert {:error, _} = Units.dimension_length("(1/0)")
      assert {:error, _} = Units.dimension_length("()")
      assert {:error, _} = Units.dimension_length("(1+)")
      assert {:error, _} = Units.dimension_length("(1/2")
      assert {:error, _} = Units.dimension_length("1++2")
    end
  end

  describe "bare-pixel fractional results round like TwicPics" do
    # Empirically verified against the live hosted TwicPics API: it rounds bare
    # pixel results half away from zero and clamps dimensions to >= 1.
    test "round half away from zero" do
      assert Units.dimension_length("(7/2)") == {:ok, {:px, 4}}
      assert Units.dimension_length("7.2") == {:ok, {:px, 7}}
      assert Units.dimension_length("2.5") == {:ok, {:px, 3}}
      assert Units.dimension_length("200.4") == {:ok, {:px, 200}}
      assert Units.dimension_length("200.5") == {:ok, {:px, 201}}
      assert Units.dimension_length("201.5") == {:ok, {:px, 202}}
    end

    test "strictly-positive value that rounds down to zero clamps to 1 (dimension)" do
      assert Units.dimension_length("(1/4)") == {:ok, {:px, 1}}
      assert Units.dimension_length("0.4") == {:ok, {:px, 1}}
    end

    test "exact zero / negative value is rejected (dimension), not clamped" do
      assert {:error, _} = Units.dimension_length("(2-2)")
      assert {:error, _} = Units.dimension_length("(1-2)")
    end

    test "positions round but allow zero and apply no >= 1 clamp" do
      assert Units.position_length("(2-2)") == {:ok, {:px, 0}}
      assert Units.position_length("0.4") == {:ok, {:px, 0}}
      assert Units.position_length("(7/2)") == {:ok, {:px, 4}}
      assert {:error, _} = Units.position_length("(1-2)")
    end
  end

  describe "decimal literals follow the JSON number grammar" do
    # Live TwicPics 404s a malformed decimal: a leading dot (`.5`), a trailing dot
    # (`5.`), or a leading zero on the integer part (`00.5`, `01`). A digit is
    # required on both sides of the dot; the integer part is `0` or a no-leading-
    # zero run. Fractions may carry leading zeros (`0.05`).
    test "accepts well-formed decimals" do
      assert Units.dimension_length("0.5") == {:ok, {:px, 1}}
      assert Units.dimension_length("1.5") == {:ok, {:px, 2}}
      assert Units.dimension_length("5.0") == {:ok, {:px, 5}}
      assert Units.dimension_length("0.05s") == {:ok, {:ratio, 1, 20}}
    end

    test "rejects a leading or trailing dot" do
      assert {:error, _} = Units.dimension_length(".5")
      assert {:error, _} = Units.dimension_length("5.")
      assert {:error, _} = Units.dimension_length("(.5)")
      assert {:error, _} = Units.dimension_length("(5.*2)")
      assert {:error, _} = Units.ratio(".5:2")
      assert {:error, _} = Units.ratio("1:5.")
    end

    test "rejects a leading zero on the integer part" do
      assert {:error, _} = Units.dimension_length("01")
      assert {:error, _} = Units.dimension_length("00.5")
      assert {:error, _} = Units.dimension_length("(01)")
      assert {:error, _} = Units.ratio("00.5:2")
    end
  end

  describe "JSON exponent notation" do
    # Live TwicPics accepts a JSON exponent suffix on a number: `[eE][+-]?[0-9]+`
    # over a well-formed mantissa, folded as mantissa x 10^exp. Probed:
    # 1e2->100, 1E2->100, (2e1)->20, 1e+2->100, 1.5e2->150, 1e02->100 (leading
    # zero allowed in the *exponent*), 5e-1=0.5->1, 15e-1=1.5->2, 4e-1=0.4->1.
    test "accepts an exponent on a bare integer or decimal mantissa" do
      assert Units.dimension_length("1e2") == {:ok, {:px, 100}}
      assert Units.dimension_length("1E2") == {:ok, {:px, 100}}
      assert Units.dimension_length("(2e1)") == {:ok, {:px, 20}}
      assert Units.dimension_length("1e+2") == {:ok, {:px, 100}}
      assert Units.dimension_length("1.5e2") == {:ok, {:px, 150}}
      assert Units.dimension_length("1e02") == {:ok, {:px, 100}}
    end

    test "a negative exponent stays exact for p/s and rounds/clamps for bare px" do
      assert Units.dimension_length("5e-1s") == {:ok, {:ratio, 1, 2}}
      assert Units.dimension_length("15e-1") == {:ok, {:px, 2}}
      assert Units.dimension_length("4e-1") == {:ok, {:px, 1}}
    end

    test "exponents work in arithmetic and ratio sides" do
      assert Units.dimension_length("(1e1*3)") == {:ok, {:px, 30}}
      assert Units.ratio("1e1:2") == {:ok, {:ratio, 5, 1}}
    end

    test "extreme exponents fold via exact rationals (deliberate divergence)" do
      # TwicPics parses numbers into IEEE-754 doubles and 404s overflow/underflow
      # (`1e309`, `1e-1000`). ImagePipe uses exact rationals by design, so it
      # accepts any magnitude: an overflow folds to a huge `{:px, n}` (later bound
      # by downstream dimension limits), an underflow clamps to 1px. Pinned so the
      # divergence stays intentional — see docs/twicpics_support_matrix.md.
      assert {:ok, {:px, _huge}} = Units.dimension_length("1e1000")
      assert Units.dimension_length("1e-1000") == {:ok, {:px, 1}}
    end

    test "rejects malformed exponents and a zero/leading-zero mantissa" do
      assert {:error, _} = Units.dimension_length("1e")
      assert {:error, _} = Units.dimension_length("e2")
      assert {:error, _} = Units.dimension_length("1e+")
      assert {:error, _} = Units.dimension_length("1.e2")
      assert {:error, _} = Units.dimension_length("1e2.5")
      assert {:error, _} = Units.dimension_length("1ee2")
      assert {:error, _} = Units.dimension_length("0e2")
      assert {:error, _} = Units.dimension_length("01e2")
    end
  end

  describe "arithmetic in ratio sides" do
    test "folds each side to an exact integer ratio" do
      assert Units.ratio("(5*2):3") == {:ok, {:ratio, 10, 3}}
      assert Units.ratio("(16):9") == {:ok, {:ratio, 16, 9}}
      assert Units.ratio("(3/2):2") == {:ok, {:ratio, 3, 4}}
    end

    test "rejects a non-positive folded side" do
      assert {:error, _} = Units.ratio("(2-2):9")
    end
  end

  describe "anchor/1" do
    test "the eight anchors map to plan guides" do
      assert Units.anchor("top-left") == {:ok, {:anchor, :left, :top}}
      assert Units.anchor("top") == {:ok, {:anchor, :center, :top}}
      assert Units.anchor("bottom-right") == {:ok, {:anchor, :right, :bottom}}
      assert Units.anchor("left") == {:ok, {:anchor, :left, :center}}
    end

    test "center is not a valid anchor" do
      assert {:error, _} = Units.anchor("center")
    end
  end
end

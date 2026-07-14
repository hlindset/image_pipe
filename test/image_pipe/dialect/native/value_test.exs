defmodule ImagePipe.Dialect.Native.ValueTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Native.Value

  describe "number/1" do
    valid = [
      {"0", 0},
      {"90", 90},
      {"2.5", 2.5},
      {"-10", -10},
      {"-0.5", -0.5},
      {"1000000", 1_000_000},
      {"0.0", 0.0}
    ]

    for {input, expected} <- valid do
      test "parses valid decimal #{inspect(input)}" do
        assert Value.number(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end

    invalid = [
      "",
      "abc",
      "1.",
      ".5",
      "+5",
      "1,5",
      "1e5",
      "--5",
      " 5",
      "5 ",
      "1.2.3",
      "5px"
    ]

    for input <- invalid do
      test "rejects invalid decimal #{inspect(input)}" do
        assert Value.number(unquote(input)) == {:error, :invalid_number}
      end
    end
  end

  describe "length/1" do
    valid = [
      {"80", {:px, 80}},
      {"0", {:px, 0}},
      {"80pct", {:pct, 80}},
      {"60.5pct", {:pct, 60.5}},
      {"-10", {:px, -10}},
      {"0pct", {:pct, 0}}
    ]

    for {input, expected} <- valid do
      test "parses valid length #{inspect(input)}" do
        assert Value.length(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end

    invalid = [
      "80p",
      "pct",
      "80%",
      "80 pct",
      "",
      "pctpct",
      "80PCT"
    ]

    for input <- invalid do
      test "rejects invalid length #{inspect(input)}" do
        assert Value.length(unquote(input)) == {:error, :invalid_length}
      end
    end
  end

  describe "dimension/1" do
    valid = [
      {"auto", :auto},
      {"1", {:px, 1}},
      {"800", {:px, 800}},
      {"007", {:px, 7}}
    ]

    for {input, expected} <- valid do
      test "parses valid dimension #{inspect(input)}" do
        assert Value.dimension(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end

    invalid = [
      "0",
      "-5",
      "5.5",
      "",
      "Auto",
      "auto1",
      "1auto",
      " 5"
    ]

    for input <- invalid do
      test "rejects invalid dimension #{inspect(input)}" do
        assert Value.dimension(unquote(input)) == {:error, :invalid_dimension}
      end
    end
  end

  describe "fraction/1" do
    valid = [
      {"0", 0.0},
      {"1", 1.0},
      {"0.5", 0.5},
      {"0.25", 0.25},
      {"1.0", 1.0},
      {"0.0", 0.0}
    ]

    for {input, expected} <- valid do
      test "parses valid fraction #{inspect(input)}" do
        assert Value.fraction(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end

    invalid = [
      "-0.1",
      "1.1",
      "2",
      "-1",
      "",
      "abc"
    ]

    for input <- invalid do
      test "rejects invalid fraction #{inspect(input)}" do
        assert Value.fraction(unquote(input)) == {:error, :invalid_fraction}
      end
    end
  end

  describe "color/1 — CSS basic color names" do
    names = [
      {"black", {0, 0, 0}},
      {"silver", {192, 192, 192}},
      {"gray", {128, 128, 128}},
      {"white", {255, 255, 255}},
      {"maroon", {128, 0, 0}},
      {"red", {255, 0, 0}},
      {"purple", {128, 0, 128}},
      {"fuchsia", {255, 0, 255}},
      {"green", {0, 128, 0}},
      {"lime", {0, 255, 0}},
      {"olive", {128, 128, 0}},
      {"yellow", {255, 255, 0}},
      {"navy", {0, 0, 128}},
      {"blue", {0, 0, 255}},
      {"teal", {0, 128, 128}},
      {"aqua", {0, 255, 255}}
    ]

    # Pin the full 16-name set so the table can't silently shrink.
    test "covers all 16 CSS basic color names" do
      assert length(unquote(Macro.escape(names))) == 16
    end

    for {name, rgb} <- names do
      test "parses CSS basic color name #{inspect(name)}" do
        assert Value.color(unquote(name)) == {:ok, unquote(Macro.escape(rgb))}
      end
    end
  end

  describe "color/1 — hex normalization" do
    valid = [
      {"fff", {255, 255, 255}},
      {"FFF", {255, 255, 255}},
      {"ffffff", {255, 255, 255}},
      {"FFFFFF", {255, 255, 255}},
      {"000", {0, 0, 0}},
      {"000000", {0, 0, 0}},
      {"f4f4f4", {244, 244, 244}},
      {"F4F4F4", {244, 244, 244}},
      {"abc", {170, 187, 204}},
      {"aabbcc", {170, 187, 204}}
    ]

    for {input, expected} <- valid do
      test "parses hex color #{inspect(input)}" do
        assert Value.color(unquote(input)) == {:ok, unquote(Macro.escape(expected))}
      end
    end

    test "3-digit and 6-digit spellings of the same color yield the same tuple" do
      assert Value.color("fff") == Value.color("ffffff")
      assert Value.color("abc") == Value.color("aabbcc")
    end

    invalid = [
      "#fff",
      "#ffffff",
      "ff",
      "ffff",
      "fffffg",
      "",
      "gray1",
      "White",
      "RED",
      "12345"
    ]

    for input <- invalid do
      test "rejects invalid color #{inspect(input)}" do
        assert Value.color(unquote(input)) == {:error, :invalid_color}
      end
    end
  end

  describe "color/1 — extended CSS named colors" do
    names = [
      {"rebeccapurple", {102, 51, 153}},
      {"cyan", {0, 255, 255}},
      {"magenta", {255, 0, 255}},
      {"grey", {128, 128, 128}},
      {"orange", {255, 165, 0}},
      {"hotpink", {255, 105, 180}}
    ]

    for {name, rgb} <- names do
      test "parses extended CSS color name #{inspect(name)}" do
        assert Value.color(unquote(name)) == {:ok, unquote(Macro.escape(rgb))}
      end
    end

    test "rejects an unknown color name" do
      assert Value.color("notacolor") == {:error, :invalid_color}
    end
  end

  describe "color/1 — alias equivalence" do
    test "aqua and cyan resolve to the same tuple" do
      assert Value.color("aqua") == Value.color("cyan")
    end

    test "fuchsia and magenta resolve to the same tuple" do
      assert Value.color("fuchsia") == Value.color("magenta")
    end

    test "gray and grey resolve to the same tuple" do
      assert Value.color("gray") == Value.color("grey")
    end
  end

  describe "pad_shorthand/1" do
    test "1 value expands to all four sides" do
      assert Value.pad_shorthand("10") == {:ok, {10, 10, 10, 10}}
      assert Value.pad_shorthand("0") == {:ok, {0, 0, 0, 0}}
    end

    test "2 values expand to top/bottom, right/left" do
      assert Value.pad_shorthand("10,20") == {:ok, {10, 20, 10, 20}}
    end

    test "3 values expand to top, right/left, bottom" do
      assert Value.pad_shorthand("10,20,30") == {:ok, {10, 20, 30, 20}}
    end

    test "4 values map directly to top, right, bottom, left" do
      assert Value.pad_shorthand("10,20,30,40") == {:ok, {10, 20, 30, 40}}
    end

    invalid = [
      "",
      "10,20,30,40,50",
      "10,-5",
      "10,abc",
      "10.5",
      "-1",
      "10, 20"
    ]

    for input <- invalid do
      test "rejects invalid pad shorthand #{inspect(input)}" do
        assert Value.pad_shorthand(unquote(input)) == {:error, :invalid_pad_shorthand}
      end
    end
  end

  describe "csv/3" do
    test "parses a fixed-arity 2-element list with per-position parsers" do
      assert Value.csv("0.5,f4f4f4", 2..2, [&Value.fraction/1, &Value.color/1]) ==
               {:ok, [0.5, {244, 244, 244}]}
    end

    test "accepts a variable-arity list at the minimum arity" do
      assert Value.csv("0.5,fff", 2..3, [&Value.fraction/1, &Value.color/1, &Value.flag/1]) ==
               {:ok, [0.5, {255, 255, 255}]}
    end

    test "accepts a variable-arity list at the maximum arity" do
      assert Value.csv("0.5,fff,false", 2..3, [
               &Value.fraction/1,
               &Value.color/1,
               &Value.flag/1
             ]) ==
               {:ok, [0.5, {255, 255, 255}, false]}
    end

    test "rejects too few elements" do
      assert Value.csv("0.5", 2..3, [&Value.fraction/1, &Value.color/1, &Value.flag/1]) ==
               {:error, :invalid_arity}
    end

    test "rejects too many elements" do
      assert Value.csv("0.5,fff,false,x", 2..3, [
               &Value.fraction/1,
               &Value.color/1,
               &Value.flag/1
             ]) ==
               {:error, :invalid_arity}
    end

    test "rejects an element that fails its position's parser" do
      assert Value.csv("0.5,notacolor", 2..2, [&Value.fraction/1, &Value.color/1]) ==
               {:error, :invalid_element}
    end

    test "rejects an empty string against a minimum arity of 1" do
      assert Value.csv("", 1..1, [&Value.number/1]) == {:error, :invalid_element}
    end

    test "fixed arity 1 parses a single element" do
      assert Value.csv("16:9", 1..1, [&Value.number/1]) == {:error, :invalid_element}
      assert Value.csv("42", 1..1, [&Value.number/1]) == {:ok, [42]}
    end
  end

  describe "flag/1" do
    test "false spelled out parses to false" do
      assert Value.flag("false") == {:ok, false}
    end

    test "true spelled out is a specific error, not a generic invalid value" do
      assert Value.flag("true") == {:error, :true_spelled_bare}
    end

    invalid = ["0", "False", "TRUE", "", "yes", "no"]

    for input <- invalid do
      test "rejects invalid flag value #{inspect(input)}" do
        assert Value.flag(unquote(input)) == {:error, :invalid_flag}
      end
    end
  end
end

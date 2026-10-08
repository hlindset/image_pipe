defmodule ImagePipe.API.GrammarScanPropertyTest do
  # The URL grammar's character checks accept exactly what these regexes do.
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.Value
  alias ImagePipe.Plan.Color

  import ImagePipe.Plan.ValueBounds

  defp text(alphabet) do
    alphabet
    |> String.graphemes()
    |> StreamData.member_of()
    |> StreamData.list_of(max_length: 8)
    |> StreamData.map(&Enum.join/1)
  end

  property "numbers" do
    check all string <- text("0123-.x") do
      assert match?({:ok, _}, Value.number(string)) ==
               Regex.match?(~r/\A-?[0-9]+(\.[0-9]+)?\z/, string)
    end
  end

  property "unsigned and signed integers" do
    check all string <- text("0129-+ x") do
      unsigned? = Regex.match?(~r/\A[0-9]+\z/, string)
      assert match?({:ok, _}, OptionSpec.parse_page(string)) == unsigned?

      signed? =
        Regex.match?(~r/\A-?[0-9]+\z/, string) and String.to_integer(string) in -255..255

      assert match?({:ok, _}, OptionSpec.parse_brightness(string)) == signed?
    end
  end

  property "positive decimals" do
    check all string <- text("0123.-x") do
      expected =
        Regex.match?(~r/\A[0-9]+(?:\.[0-9]+)?\z/, string) and
          scale?(elem(Float.parse(string), 0))

      assert match?({:ok, _}, OptionSpec.parse_dpr(string)) == expected
    end
  end

  property "names and tokens" do
    check all string <- text("aZ09._-~ !") do
      assert match?({:ok, _}, OptionSpec.parse_watermark(string)) ==
               Regex.match?(~r/\A[a-z0-9_-]+\z/, string)

      assert match?({:ok, _}, OptionSpec.parse_preset_names(string)) ==
               Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, string)

      detect? = string != "unset" and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, string)
      assert match?({:ok, _}, OptionSpec.parse_detect(string)) == detect?

      unless Regex.match?(~r/\A([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})\z/, string) do
        css? =
          Regex.match?(~r/\A[a-z]+\z/, string) and
            match?({:ok, _}, Color.rgb_name(string))

        assert match?({:ok, _}, Value.color(string)) == css?
      end
    end
  end

  property "builder names" do
    check all string <- text("aZ09._-~ !") do
      valid? = fn options ->
        match?(
          {:ok, _},
          ImagePipe.Plan.built(ImagePipe.URL.group(ImagePipe.URL.new(), options).plan)
        )
      end

      assert valid?.(presets: [string]) == Regex.match?(~r/\A[A-Za-z0-9._-]+\z/, string)

      detect? = string != "all" and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, string)
      assert valid?.(detect: [string]) == detect?

      if Regex.match?(~r/\A[a-z0-9_-]+\z/, string) do
        assert valid?.(watermark: String.to_atom(string))
      end
    end
  end
end

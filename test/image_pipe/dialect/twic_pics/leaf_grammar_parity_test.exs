defmodule ImagePipe.Dialect.TwicPics.LeafGrammarParityTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics.Manipulation, as: DialectManipulation
  alias ImagePipe.Dialect.TwicPics.Output, as: DialectOutput
  alias ImagePipe.Dialect.TwicPics.Path, as: DialectPath
  alias ImagePipe.Dialect.TwicPics.Source, as: DialectSource
  alias ImagePipe.Dialect.TwicPics.Units, as: DialectUnits
  alias ImagePipe.Parser.TwicPics.Manipulation, as: LegacyManipulation
  alias ImagePipe.Parser.TwicPics.Output, as: LegacyOutput
  alias ImagePipe.Parser.TwicPics.Path, as: LegacyPath
  alias ImagePipe.Parser.TwicPics.Source, as: LegacySource
  alias ImagePipe.Parser.TwicPics.Units, as: LegacyUnits

  @legacy_modules [
    manipulation: LegacyManipulation,
    units: LegacyUnits,
    output: LegacyOutput,
    source: LegacySource,
    path: LegacyPath
  ]

  @dialect_modules [
    manipulation: DialectManipulation,
    units: DialectUnits,
    output: DialectOutput,
    source: DialectSource,
    path: DialectPath
  ]

  @cases [
    %{family: {:manipulation, :parse, 1}, input: "v1", outcome: :success},
    %{
      family: {:manipulation, :parse, 1},
      input: "v1/resize=(100/(4/2))/output=png",
      outcome: :success
    },
    %{family: {:manipulation, :parse, 1}, input: "v2/resize=10", outcome: :error},
    %{family: {:manipulation, :parse, 1}, input: "v1/resize", outcome: :error},
    %{family: {:units, :dimension_length, 1}, input: "(100/(4/2))", outcome: :success},
    %{family: {:units, :dimension_length, 1}, input: "(1/3)p", outcome: :success},
    %{family: {:units, :dimension_length, 1}, input: "(1/3)s", outcome: :success},
    %{family: {:units, :dimension_length, 1}, input: "1e1000", outcome: :success},
    %{family: {:units, :dimension_length, 1}, input: "1e-1000", outcome: :success},
    %{family: {:units, :dimension_length, 1}, input: "(1/0)", outcome: :error},
    %{family: {:units, :dimension_length, 1}, input: "((1+2)", outcome: :error},
    %{family: {:units, :dimension_length, 1}, input: "1e+", outcome: :error},
    %{family: {:units, :position_length, 1}, input: "0", outcome: :success},
    %{family: {:units, :position_length, 1}, input: "0.4", outcome: :success},
    %{family: {:units, :position_length, 1}, input: "(1-2)", outcome: :error},
    %{family: {:units, :size, 1}, input: "10px150", outcome: :success},
    %{family: {:units, :size, 1}, input: "250px", outcome: :success},
    %{family: {:units, :size, 1}, input: "abcx150", outcome: :error},
    %{family: {:units, :crop_size, 1}, input: "320x-", outcome: :success},
    %{family: {:units, :crop_size, 1}, input: "-x0", outcome: :error},
    %{family: {:units, :ratio, 1}, input: "(3/2):2", outcome: :success},
    %{family: {:units, :ratio, 1}, input: "1e1:2", outcome: :success},
    %{family: {:units, :ratio, 1}, input: "(2-2):9", outcome: :error},
    %{family: {:units, :ratio, 1}, input: "1.5.2:2", outcome: :error},
    %{family: {:units, :coordinates, 1}, input: "0x50p", outcome: :success},
    %{family: {:units, :coordinates, 1}, input: "-1x0", outcome: :error},
    %{family: {:units, :anchor, 1}, input: "top-left", outcome: :success},
    %{family: {:units, :anchor, 1}, input: "center", outcome: :error},
    %{family: {:output, :format, 1}, input: "jpeg", outcome: :success},
    %{family: {:output, :format, 1}, input: "blurhash", outcome: :error},
    %{family: {:output, :quality, 1}, input: "1", outcome: :success},
    %{family: {:output, :quality, 1}, input: "100", outcome: :success},
    %{family: {:output, :quality, 1}, input: "0", outcome: :error},
    %{family: {:output, :quality, 1}, input: "101", outcome: :error},
    %{
      family: {:output, :build, 1},
      input: %{format: :auto, quality: :default},
      outcome: :success
    },
    %{
      family: {:output, :build, 1},
      input: %{format: :webp, quality: {:quality, 73}},
      outcome: :success
    },
    %{
      family: {:source, :from_segments, 1},
      input: ["folder%2Fname", "beach%20day.jpg"],
      outcome: :success
    },
    %{family: {:source, :from_segments, 1}, input: [], outcome: :error},
    %{family: {:source, :from_segments, 1}, input: ["images", ""], outcome: :error},
    %{
      family: {:path, :extract, 1},
      input: "/folder%2Fname/beach%20day.jpg?twic=v1/resize=(700/2)",
      outcome: :success
    },
    %{family: {:path, :extract, 1}, input: "/images/beach.jpg", outcome: :error},
    %{family: {:path, :extract, 1}, input: "/?twic=v1/resize=100", outcome: :error}
  ]

  test "corpus covers both outcomes" do
    assert MapSet.new(Enum.map(@cases, & &1.outcome)) == MapSet.new([:success, :error])
  end

  test "dialect copy returns the complete legacy term for every corpus case" do
    Enum.each(@cases, fn test_case ->
      legacy_result = invoke(@legacy_modules, test_case.family, test_case.input)
      dialect_result = invoke(@dialect_modules, test_case.family, test_case.input)

      assert dialect_result == legacy_result,
             "parity mismatch for #{inspect(test_case.family)} with #{inspect(test_case.input)}"

      assert outcome(dialect_result) == test_case.outcome,
             "wrong outcome classification for #{inspect(test_case.family)} with #{inspect(test_case.input)}"
    end)
  end

  defp invoke(modules, {family, function, 1}, input) do
    module = Keyword.fetch!(modules, family)
    apply(module, function, [argument(family, input)])
  end

  defp argument(:path, request_path), do: conn(:get, request_path)
  defp argument(_family, input), do: input

  defp outcome({:ok, _value}), do: :success
  defp outcome({:ok, _source, _manipulation}), do: :success
  defp outcome({:error, _reason}), do: :error
end

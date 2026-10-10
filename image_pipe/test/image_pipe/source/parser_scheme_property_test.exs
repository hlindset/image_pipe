defmodule ImagePipe.Source.ParserSchemePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Source.Parser
  alias ImagePipe.Source.Path

  property "a source is a URL exactly when it starts with a scheme prefix" do
    check all chars <- list_of(member_of(String.graphemes("aZ9+.-:/_")), max_length: 10) do
      source = Enum.join(chars)

      expected =
        case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\//, source) do
          [_match, scheme] ->
            {:error, {:invalid_source, {:unsupported_scheme, String.downcase(scheme)}}}

          nil ->
            :path
        end

      case Parser.translate(source, []) do
        {:ok, %Path{}} -> assert expected == :path
        {:error, {:invalid_source, :empty_source}} -> assert source in ["", "/"]
        other -> assert other == expected
      end
    end
  end
end

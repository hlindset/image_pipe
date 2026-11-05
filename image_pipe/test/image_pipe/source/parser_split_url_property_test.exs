defmodule ImagePipe.Source.ParserSplitURLPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Source.Parser

  @fields [:userinfo, :host, :path, :query, :fragment]

  property "splits a scheme:// source as URI.parse/1 does" do
    check all scheme <- member_of(["http", "HTTPS", "s3", "x+y.z-1"]),
              chars <- list_of(member_of(String.graphemes("aZ9.-_~@[]:/?#%\n é")), max_length: 24),
              max_runs: 2_000 do
      source = scheme <> "://" <> Enum.join(chars)

      assert Map.take(Parser.split_url(source), @fields) ==
               Map.take(URI.parse(source), @fields)
    end
  end

  test "agrees with URI.parse/1 on edge cases" do
    for rest <- [
          "",
          "/",
          "host",
          "host/",
          "host?",
          "host#",
          "host?q#f",
          "@host/p",
          "u@v@host:80/p",
          "u\n@host/p",
          "[::1]:8080/p",
          "[fe80::1%25eth0]/p",
          "[]/p",
          "[[x]]/p",
          "[::1/p",
          "host:/p",
          "host:abc/p",
          "host/a?b?c#d#e"
        ] do
      source = "http://" <> rest
      assert Map.take(Parser.split_url(source), @fields) == Map.take(URI.parse(source), @fields)
    end
  end
end

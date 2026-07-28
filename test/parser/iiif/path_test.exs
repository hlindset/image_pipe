defmodule ImagePipe.Parser.IIIF.PathTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Dialect.IIIF.Path

  defp conn_for(path), do: conn(:get, path)

  test "single segment -> :redirect with absolute info.json location" do
    conn = %{conn_for("/abc") | script_name: ["iiif"]}
    assert {:redirect, "abc", location} = Path.classify(conn)
    assert String.ends_with?(location, "/iiif/abc/info.json")
  end

  test "two segments ending in info.json -> :info" do
    assert {:info, "abc"} = Path.classify(conn_for("/abc/info.json"))
  end

  test "five segments -> :image with split quality.format" do
    assert {:image, "abc",
            %{region: "full", size: "max", rotation: "0", quality: "default", format: "jpg"}} =
             Path.classify(conn_for("/abc/full/max/0/default.jpg"))
  end

  test "unescaped-slash identifier (extra segment) -> :not_found" do
    assert :not_found = Path.classify(conn_for("/a/b/full/max/0/default.jpg"))
  end

  test "percent-encoded tokens are decoded (RFC 3986), not just the id" do
    # `:` -> %3A and `,` -> %2C (pct region), `^` -> %5E (upscaling size). path_info
    # arrives undecoded, so classify must decode every token, not only the identifier.
    assert {:image, "abc",
            %{
              region: "pct:10,10,50,50",
              size: "^400,",
              rotation: "0",
              quality: "default",
              format: "jpg"
            }} =
             Path.classify(conn_for("/abc/pct%3A10%2C10,50,50/%5E400,/0/default.jpg"))
  end
end

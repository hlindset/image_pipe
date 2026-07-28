defmodule ImagePipe.Parser.IIIF.Resolver.StaticTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.IIIF.Resolver.Static
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @map %{"abc" => %SourcePath{segments: ["images", "beach.jpg"]}}

  test "resolves a known identifier to its configured source" do
    assert {:ok, %SourcePath{segments: ["images", "beach.jpg"]}} =
             Static.resolve("abc", map: @map)
  end

  test "unknown identifier -> {:error, :not_found}" do
    assert {:error, :not_found} = Static.resolve("nope", map: @map)
  end
end

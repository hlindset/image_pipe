defmodule ImagePipe.Dialect.TwicPics.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Source
  alias ImagePipe.Plan.Source, as: PlanSource

  describe "from_segments/1" do
    test "builds a path source from decoded segments" do
      assert Source.from_segments(["images", "beach%20day.jpg"]) ==
               {:ok, %PlanSource.Path{segments: ["images", "beach day.jpg"]}}
    end

    test "preserves slash characters decoded within a segment" do
      assert Source.from_segments(["folder%2Fname", "image.jpg"]) ==
               {:ok, %PlanSource.Path{segments: ["folder/name", "image.jpg"]}}
    end

    test "rejects an empty source path" do
      assert Source.from_segments([]) == {:error, :invalid_source_path}
    end
  end
end

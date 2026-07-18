defmodule ImagePipe.Dialect.TwicPics.PathTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics.Path
  alias ImagePipe.Plan.Source

  test "builds a Source.Path from path_info and extracts the twic chain" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/resize=100")

    assert {:ok, %Source.Path{segments: ["images", "beach.jpg"]}, "v1/resize=100"} =
             Path.extract(conn)
  end

  test "missing twic param is an error" do
    conn = conn(:get, "/images/beach.jpg")
    assert {:error, :missing_manipulation} = Path.extract(conn)
  end

  test "empty source path is an error" do
    conn = conn(:get, "/?twic=v1/resize=100")
    assert {:error, :invalid_source_path} = Path.extract(conn)
  end
end

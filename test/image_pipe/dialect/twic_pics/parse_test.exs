defmodule ImagePipe.Dialect.TwicPics.ParseTest do
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 2]

  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.RequestSafetyTest.CacheProbe
  alias ImagePipe.SourceTest.RaisingAdapter

  test "missing twic is rejected before source or cache access" do
    assert {:error, :missing_manipulation} = parse("/images/cat.jpg")
    refute_received :cache_lookup
  end

  test "bad manipulation version is rejected before source or cache access" do
    assert {:error, {:unsupported_manipulation_version, "v2/resize=10"}} =
             parse("/images/cat.jpg?twic=v2/resize=10")

    refute_received :cache_lookup
  end

  test "malformed manipulation segment is rejected before source or cache access" do
    assert {:error, {:invalid_segment, "resize"}} =
             parse("/images/cat.jpg?twic=v1/resize")

    refute_received :cache_lookup
  end

  test "unsupported transform is rejected before source or cache access" do
    assert {:error, {:unsupported_transform, "zoom"}} =
             parse("/images/cat.jpg?twic=v1/zoom=2")

    refute_received :cache_lookup
  end

  test "valid path composes into one complete ordered request" do
    assert {:ok,
            %Request{
              source: %Path{segments: ["images", "cat.jpg"]},
              steps: [
                {:set_focus, {:anchor, :center, :top}},
                {:operation, %Operation.Resize{mode: :fit, width: {:px, 200}}},
                {:focused,
                 %Operation.CropGuided{
                   guide: :center,
                   aspect_ratio: {:ratio, 4, 3}
                 }}
              ],
              output: %Output{mode: {:explicit, :webp}, quality: {:quality, 72}},
              response: %Response{debug?: true},
              auto_rotate: true
            }} =
             parse(
               "/images/cat.jpg?twic=v1/focus=top/resize=200/cover=4:3/output=webp/quality=72/debug=1"
             )

    refute_received :cache_lookup
  end

  defp parse(path) do
    TwicPics.parse(conn(:get, path), config())
  end

  defp config do
    TwicPics.init(
      sources: [path: {RaisingAdapter, []}],
      cache: {CacheProbe, []}
    )
  end
end

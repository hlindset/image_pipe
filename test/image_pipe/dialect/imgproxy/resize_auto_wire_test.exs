defmodule ImagePipe.Dialect.Imgproxy.ResizeAutoWireTest do
  @moduledoc """
  Wire-level coverage for the neutral `resize:auto` fill-vs-fit bucketing
  (#233, promoted to `ImagePipe.Transform.NeutralResolver` in #448) on the
  imgproxy dialect surface.

  These drive full requests through `ImagePipe.Dialect.Imgproxy.init/1` +
  `call/2` — the source is resolved and fetched for real — and assert the
  decoded output dimensions, pinning the bucketing end-to-end rather than at
  the resolver unit.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy

  defmodule GeneratedSourceAdapter do
    @behaviour ImagePipe.Source

    alias ImagePipe.Plan.Source.Path, as: SourcePath
    alias ImagePipe.Source.CacheSemantics
    alias ImagePipe.Source.Resolved

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(%SourcePath{segments: segments}, _opts, _runtime_opts) do
      {width, height} = segments |> List.last() |> dimensions()

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [
           kind: :path,
           adapter: :path,
           root: "generated",
           path: segments
         ],
         internal_cache: :enabled,
         http_cache: :inherit,
         cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
         fetch: {width, height}
       }}
    end

    @impl ImagePipe.Source
    def fetch(%Resolved{fetch: {width, height}}, _opts, _runtime_opts) do
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      {:ok, %ImagePipe.Source.Response{stream: [body]}}
    end

    defp dimensions(basename) do
      [width, height] =
        basename
        |> Path.rootname()
        |> String.split("x")
        |> Enum.map(&String.to_integer/1)

      {width, height}
    end
  end

  defp call_auto({sw, sh}, {tw, th}) do
    opts =
      ImagePipe.Plug.init(
        dialect: Imgproxy,
        sources: [path: {GeneratedSourceAdapter, []}],
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000
      )

    conn(:get, "/unsafe/rt:auto/w:#{tw}/h:#{th}/f:jpeg/plain/generated/#{sw}x#{sh}.png")
    |> ImagePipe.Plug.call(opts)
  end

  defp assert_auto_dimensions(source, target, expected) do
    conn = call_auto(source, target)
    assert conn.status == 200
    assert {:ok, image} = Image.open(conn.resp_body, access: :random, fail_on: :error)
    assert {Image.width(image), Image.height(image)} == expected
  end

  test "1. request-level resize:auto from 300x200 to 100x50 returns 100x50" do
    assert_auto_dimensions({300, 200}, {100, 50}, {100, 50})
  end

  test "2. request-level resize:auto from 300x200 to 50x100 returns 50x33" do
    assert_auto_dimensions({300, 200}, {50, 100}, {50, 33})
  end

  test "3. request-level resize:auto from 100x100 to 50x50 returns 50x50" do
    assert_auto_dimensions({100, 100}, {50, 50}, {50, 50})
  end

  test "4. request-level resize:auto from 100x100 to 50x80 returns 50x50" do
    assert_auto_dimensions({100, 100}, {50, 80}, {50, 50})
  end

  # #233: imgproxy buckets fill-vs-fit by the sign of width−height, with square
  # (diff == 0) sharing the non-negative (landscape) bucket. So square↔landscape
  # pairs fill (cover + result-crop), not fit. (processing/prepare.go:88-97)

  test "5. resize:auto square source 100x100 into landscape 100x50 fills to 100x50" do
    assert_auto_dimensions({100, 100}, {100, 50}, {100, 50})
  end

  test "6. resize:auto landscape source 200x100 into square 50x50 fills to 50x50" do
    assert_auto_dimensions({200, 100}, {50, 50}, {50, 50})
  end

  test "7. resize:auto portrait source 100x200 into square 50x50 fits to 25x50" do
    assert_auto_dimensions({100, 200}, {50, 50}, {25, 50})
  end
end

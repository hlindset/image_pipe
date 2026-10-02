defmodule ImagePipe.APIImgproxyReferenceTest do
  @moduledoc """
  Pixel references baked by upstream imgproxy and exercised through ImagePipe's
  URL API.

  See `test/support/image_pipe/test/imgproxy_reference/README.md` for fixture
  provenance and change rules. A failing case writes its actual output and an
  amplified difference image to `tmp/imgproxy_reference/`.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.ImgproxyReference.Cases
  alias Vix.Vips.Operation

  @sources "test/support/image_pipe/test/sources"
  @reference "test/support/image_pipe/test/imgproxy_reference"
  @fixtures Path.join(@reference, "fixtures")
  @failures "tmp/imgproxy_reference"
  @manifest @reference |> Path.join("manifest.exs") |> Code.eval_file() |> elem(0)

  setup_all do
    config =
      ImagePipe.Plug.init(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: @sources, root_id: "imgproxy-reference"]
          ]
        ]
      )

    {:ok, config: config}
  end

  describe "reference" do
    for c <- Cases.all() do
      @case c
      if c[:pending], do: @tag(skip: c.pending)

      test "#{c.id}: #{c.native}", %{config: config} do
        check(@case, config)
      end
    end
  end

  describe "fixture integrity" do
    test "sources match the hashes the fixtures were baked from" do
      for {file, sha256} <- @manifest.sources do
        assert file_sha256(Path.join(@sources, file)) == sha256,
               "#{file} changed since the imgproxy fixtures were baked from it"
      end
    end

    test "every case has a manifest entry and every entry a case" do
      ids = MapSet.new(Cases.all(), & &1.id)
      assert ids == MapSet.new(Map.keys(@manifest.cases))
      assert length(Cases.all()) == MapSet.size(ids), "duplicate case ids"
    end

    test "fixtures match their recorded hashes and none are orphaned" do
      png_ids = for %{kind: :png, id: id} <- Cases.all(), do: id

      for id <- png_ids do
        assert file_sha256(fixture_path(id)) == @manifest.cases[id].fixture_sha256,
               "#{id}: fixture bytes changed; imgproxy fixtures are never re-baked"
      end

      assert @fixtures |> File.ls!() |> Enum.sort() ==
               png_ids |> Enum.map(&"#{&1}.png") |> Enum.sort()
    end

    test "every case source is recorded in the manifest" do
      for c <- Cases.all() do
        assert Map.has_key?(@manifest.sources, c.source), "#{c.id}: #{c.source} has no hash"
      end
    end
  end

  defp check(%{kind: :lossy} = c, config) do
    {body, content_type} = render(c.native, c.source, config)
    actual = Image.open!(body, access: :random, fail_on: :error)
    expected = @manifest.cases[c.id]

    assert {Image.width(actual), Image.height(actual)} == {expected.width, expected.height}
    assert content_type == expected.content_type
  end

  defp check(%{kind: :png} = c, config) do
    {body, _content_type} = render(c.native <> "/format=png", c.source, config)
    actual = Image.open!(body, access: :random, fail_on: :error)
    expected = Image.open!(fixture_path(c.id), access: :random, fail_on: :error)
    {threshold, budget} = c.tolerance

    unless PixelCompare.same_dims?(actual, expected) do
      record_failure(c.id, body, nil)

      flunk(
        "#{c.id}: dimensions #{inspect(PixelCompare.dims(actual))} != imgproxy reference " <>
          inspect(PixelCompare.dims(expected))
      )
    end

    outliers = PixelCompare.outliers(actual, expected, threshold)

    if outliers > budget do
      record_failure(c.id, body, {actual, expected})

      flunk(
        "#{c.id}: #{outliers} band samples exceed Δ#{threshold}; budget #{budget}. " <>
          "Output written to #{@failures}/"
      )
    end
  end

  defp render(native, source, config) do
    response = conn(:get, "/#{native}/src/#{source}") |> ImagePipe.Plug.call(config)

    assert response.status == 200,
           "/#{native}/src/#{source}: status #{response.status}: #{response.resp_body}"

    [content_type] = Plug.Conn.get_resp_header(response, "content-type")
    {response.resp_body, content_type}
  end

  defp record_failure(id, body, images) do
    File.mkdir_p!(@failures)
    File.write!(Path.join(@failures, "#{id}.actual.png"), body)

    with {actual, expected} <- images,
         {:ok, delta} <- Operation.subtract(actual, expected),
         {:ok, delta} <- Operation.abs(delta),
         {:ok, delta} <- Operation.linear(delta, [8.0], [0.0]),
         {:ok, delta} <- Operation.cast(delta, :VIPS_FORMAT_UCHAR) do
      Image.write!(delta, Path.join(@failures, "#{id}.diff.png"))
    end
  end

  defp fixture_path(id), do: Path.join(@fixtures, "#{id}.png")

  defp file_sha256(path),
    do: :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
end

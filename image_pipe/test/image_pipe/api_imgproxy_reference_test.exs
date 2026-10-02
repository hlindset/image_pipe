defmodule ImagePipe.APIImgproxyReferenceTest do
  @moduledoc """
  Pixel references baked by upstream imgproxy and exercised through ImagePipe's
  URL API, with each output's structure (band layout, depth, ICC profile,
  orientation and extra metadata) compared with imgproxy's.

  See `test/support/image_pipe/test/imgproxy_reference/README.md` for fixture
  provenance and change rules. Every case writes its output, an amplified
  difference image and its result to `tmp/imgproxy_reference/`;
  `mix image_pipe.pixel_report --suite reference` builds an HTML page and a
  summary from them.
  """

  use ExUnit.Case, async: true

  @moduletag :imgproxy_reference

  alias ImagePipe.Test.ImgproxyReference.Cases
  alias ImagePipe.Test.PixelSuite

  @reference "test/support/image_pipe/test/imgproxy_reference"
  @suite %{
    fixtures: Path.join(@reference, "fixtures"),
    results: "tmp/imgproxy_reference",
    label: "imgproxy reference"
  }
  @manifest @reference |> Path.join("manifest.exs") |> Code.eval_file() |> elem(0)

  setup_all do
    PixelSuite.reset!(@suite)
    {:ok, config: PixelSuite.config("imgproxy-reference")}
  end

  describe "reference" do
    for c <- Cases.all() do
      @case c
      if c[:pending], do: @tag(skip: c.pending)

      test "#{c.id}: #{c.native}", %{config: config} do
        {body, content_type} = check(@case, config)
        expected = @manifest.cases[@case.id].structure

        PixelSuite.check_structure(
          @case,
          @suite,
          PixelSuite.structure(body, content_type),
          expected,
          Map.keys(expected)
        )
      end
    end
  end

  describe "fixture integrity" do
    test "sources match the hashes the fixtures were baked from" do
      for {file, sha256} <- @manifest.sources do
        assert PixelSuite.file_sha256(Path.join(PixelSuite.sources(), file)) == sha256,
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
        assert PixelSuite.file_sha256(PixelSuite.fixture_path(@suite, id)) ==
                 @manifest.cases[id].fixture_sha256,
               "#{id}: fixture bytes changed; imgproxy fixtures are never re-baked"
      end

      assert @suite.fixtures |> File.ls!() |> Enum.sort() ==
               png_ids |> Enum.map(&"#{&1}.png") |> Enum.sort()
    end

    test "every case source is recorded in the manifest" do
      for c <- Cases.all() do
        assert Map.has_key?(@manifest.sources, c.source), "#{c.id}: #{c.source} has no hash"
      end
    end
  end

  defp check(%{kind: :lossy} = c, config),
    do: PixelSuite.check_lossy(c, config, @suite, @manifest.cases[c.id])

  defp check(%{kind: :png} = c, config), do: PixelSuite.check_pixels(c, config, @suite)
end

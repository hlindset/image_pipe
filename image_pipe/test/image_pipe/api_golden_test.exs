defmodule ImagePipe.APIGoldenTest do
  @moduledoc """
  Whole-image goldens baked from ImagePipe's own output.

  They catch unintended output changes where imgproxy can't serve as a
  reference: ImagePipe-only options, deliberate differences, output encoding
  and colour handling. Each case also compares the output's structure (content
  type, band layout, depth, ICC profile, orientation and extra metadata) with
  the structure recorded at bake time. See `test/support/image_pipe/test/golden/README.md`.
  Every case writes its output, an amplified difference image and its result to
  `tmp/golden/`; `mix image_pipe.pixel_report --suite golden` builds a page from them.
  """

  use ExUnit.Case, async: true

  @moduletag :golden

  alias ImagePipe.Test.Golden.Cases
  alias ImagePipe.Test.PixelSuite

  @base "test/support/image_pipe/test/golden"
  @suite %{fixtures: Path.join(@base, "fixtures"), results: "tmp/golden", label: "golden"}
  @manifest @base |> Path.join("manifest.exs") |> Code.eval_file() |> elem(0)

  setup_all do
    PixelSuite.reset!(@suite)
    {:ok, config: PixelSuite.config("golden")}
  end

  describe "golden" do
    for c <- Cases.all() do
      @case c

      test "#{c.id}: #{c.native}", %{config: config} do
        {body, content_type} = PixelSuite.check_pixels(@case, config, @suite)
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
    test "sources match the hashes the goldens were baked from" do
      for {file, sha256} <- @manifest.sources do
        assert PixelSuite.file_sha256(Path.join(PixelSuite.sources(), file)) == sha256,
               "#{file} changed since the goldens were baked from it; re-bake them"
      end
    end

    test "every case has a fixture recorded in the manifest, and nothing else" do
      ids = Enum.map(Cases.all(), & &1.id)
      assert length(ids) == length(Enum.uniq(ids)), "duplicate case ids"
      assert Enum.sort(ids) == @manifest.cases |> Map.keys() |> Enum.sort()

      assert @suite.fixtures |> File.ls!() |> Enum.sort() ==
               ids |> Enum.map(&"#{&1}.png") |> Enum.sort()

      for id <- ids do
        assert PixelSuite.file_sha256(PixelSuite.fixture_path(@suite, id)) ==
                 @manifest.cases[id].fixture_sha256,
               "#{id}: fixture changed outside `mix image_pipe.golden.bake`"
      end
    end
  end
end

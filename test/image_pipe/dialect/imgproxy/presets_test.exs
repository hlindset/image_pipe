defmodule ImagePipe.Dialect.Imgproxy.PresetsTest do
  @moduledoc """
  Preset-expansion *internals* for the imgproxy dialect. Expansion has no
  standalone entry point on `Dialect.Imgproxy.Presets` (unlike native's
  `expand/4`); the dialect expands presets *inside* `Options.parse/3`, so these
  drive the `Presets` + `Options` seam directly and assert on the expanded
  request's `pipelines`/`output`.

  `pr:` == inline-expansion cache-key equivalence is already covered by
  `test/image_pipe/dialect/imgproxy_contract_test.exs` and is not duplicated here.
  """

  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.Options
  alias ImagePipe.Dialect.Imgproxy.Presets

  describe "recursion guard" do
    test "skips direct recursive preset re-entry and keeps reachable options" do
      presets = presets(%{"loop" => "pr:loop/w:100/h:80/q:72"})

      assert {:ok, request} = Options.parse(["pr:loop"], presets)

      assert [pipeline] = request.pipelines
      assert pipeline.width == {:pixels, 100}
      assert pipeline.height == {:pixels, 80}
      assert request.output.quality == {:quality, 72}
    end

    test "skips indirect recursive preset re-entry and keeps reachable options" do
      presets =
        presets(%{
          "a" => "w:100/pr:b/q:70",
          "b" => "h:80/pr:a/f:webp"
        })

      assert {:ok, request} = Options.parse(["pr:a"], presets)

      assert [pipeline] = request.pipelines
      assert pipeline.width == {:pixels, 100}
      assert pipeline.height == {:pixels, 80}
      assert request.output.format == :webp
      assert request.output.quality == {:quality, 70}
    end
  end

  describe "preset references and precedence" do
    test "expands presets that reference other presets" do
      presets =
        presets(%{
          "thumb" => "w:120/h:90",
          "sharp-thumb" => "pr:thumb/q:82"
        })

      assert {:ok, request} = Options.parse(["pr:sharp-thumb"], presets)

      assert [pipeline] = request.pipelines
      assert pipeline.width == {:pixels, 120}
      assert pipeline.height == {:pixels, 90}
      assert request.output.quality == {:quality, 82}
    end

    test "applies the default preset before URL options so URL fields override it" do
      presets = presets(%{"default" => "rt:fill/w:300/h:200/q:70"})

      assert {:ok, request} = Options.parse(["w:150"], presets)

      assert [pipeline] = request.pipelines
      assert pipeline.resizing_type == :fill
      assert pipeline.width == {:pixels, 150}
      assert pipeline.height == {:pixels, 200}
      assert request.output.quality == {:quality, 70}
    end
  end

  describe "invalid preset references" do
    test "returns parser errors for empty, malformed, and unknown preset references" do
      presets = presets(%{"thumb" => "w:100"})

      assert Options.parse(["preset:"], presets) ==
               {:error, {:invalid_option_segment, "preset:"}}

      assert Options.parse(["pr::"], presets) ==
               {:error, {:invalid_option_segment, "pr::"}}

      assert Options.parse(["pr:missing"], presets) ==
               {:error, {:unknown_preset, "missing"}}
    end
  end

  describe "pipeline group merging" do
    test "merges preset pipeline groups with URL pipeline groups at the same offset" do
      presets =
        presets(%{
          "test" => "width:300/height:300/-/width:200/height:200/-/width:100/height:200"
        })

      assert {:ok, request} =
               Options.parse(
                 ["width:400", "-", "preset:test", "width:500", "-", "width:600"],
                 presets
               )

      assert [first, second, third, fourth] = request.pipelines

      assert first.width == {:pixels, 400}
      assert first.height == nil

      assert second.width == {:pixels, 500}
      assert second.height == {:pixels, 300}

      assert third.width == {:pixels, 600}
      assert third.height == {:pixels, 200}

      assert fourth.width == {:pixels, 100}
      assert fourth.height == {:pixels, 200}
    end

    test "turns trailing queued preset groups into trailing pipelines" do
      presets = presets(%{"responsive" => "w:900/-/w:450"})

      assert {:ok, request} = Options.parse(["pr:responsive"], presets)

      assert [first, second] = request.pipelines
      assert first.width == {:pixels, 900}
      assert second.width == {:pixels, 450}
    end

    test "applies default preset pipeline groups before URL groups" do
      presets = presets(%{"default" => "w:900/-/w:450"})

      assert {:ok, request} = Options.parse(["w:100", "-", "h:200"], presets)

      assert [first, second] = request.pipelines
      assert first.width == {:pixels, 100}
      assert first.height == nil
      assert second.width == {:pixels, 450}
      assert second.height == {:pixels, 200}
    end

    test "merges same-offset queued groups from multiple presets into the same later pipeline" do
      presets =
        presets(%{
          "wide" => "w:300/-/w:100",
          "tall" => "h:300/-/h:200"
        })

      assert {:ok, request} = Options.parse(["pr:wide:tall", "-", "h:400"], presets)

      assert [first, second] = request.pipelines
      assert first.width == {:pixels, 300}
      assert first.height == {:pixels, 300}
      assert second.width == {:pixels, 100}
      assert second.height == {:pixels, 400}
    end

    test "merges same-offset default and explicit preset groups into the same later pipeline" do
      presets =
        presets(%{
          "default" => "w:900/-/h:450",
          "responsive" => "h:900/-/w:450"
        })

      assert {:ok, request} = Options.parse(["pr:responsive", "-", "h:100"], presets)

      assert [first, second] = request.pipelines
      assert first.width == {:pixels, 900}
      assert first.height == {:pixels, 900}
      assert second.width == {:pixels, 450}
      assert second.height == {:pixels, 100}
    end
  end

  defp presets(definitions) do
    assert {:ok, presets} = Presets.validate_config(definitions)
    presets
  end
end

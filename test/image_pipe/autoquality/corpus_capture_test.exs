defmodule Mix.Tasks.Autoquality.Corpus.CaptureTest do
  @moduledoc """
  Unit tests for the benchmark-only screenshot-capture task (`mix
  autoquality.corpus.capture`). The task's value is reproducible, incrementally
  expandable acquisition of the >6 MP screen-content cohort, so the two contracts
  that make that work are pinned here: the committed `{name, url}` list maps each
  URL to a **stable, unique, filesystem-safe** filename, and `pending/2` selects
  **only the URLs whose file is missing** (so re-runs fill gaps and never re-capture
  — which keeps already-materialized pixels sticky). The actual `shot-scraper`
  shell-out is environmental and not exercised here.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Autoquality.Corpus.Capture

  describe "sources/0 — the committed recipe, grouped by source" do
    test "names each source with a filesystem-safe stem, shot-scraper args, and entries" do
      sources = Capture.sources()
      assert length(sources) >= 2

      for {source, extra_args, entries} <- sources do
        assert is_binary(source) and source != ""
        refute source =~ ~r/[\/\\.\s]/, "unsafe source dir: #{inspect(source)}"
        assert is_list(extra_args) and Enum.all?(extra_args, &is_binary/1)
        assert entries != []
      end
    end
  end

  describe "screenshot_urls/0 — the flattened recipe" do
    test "carries enough entries to thicken the cohort, each a {name, url} pair" do
      urls = Capture.screenshot_urls()
      assert length(urls) >= 20

      for entry <- urls do
        assert {name, url} = entry
        assert is_binary(name) and name != ""
        assert is_binary(url)
        assert String.starts_with?(url, "https://")
      end
    end

    test "names are unique — no two URLs collide on a filename" do
      names = Capture.screenshot_urls() |> Enum.map(&elem(&1, 0))
      assert names == Enum.uniq(names)
    end

    test "names are filesystem-safe stems (no separators, dots, or whitespace)" do
      for {name, _url} <- Capture.screenshot_urls() do
        refute name =~ ~r/[\/\\.\s]/, "unsafe filename stem: #{inspect(name)}"
      end
    end
  end

  describe "target_path/2 — stable URL→filename mapping" do
    test "is a pure function of the dir and committed name" do
      assert Capture.target_path("/corpus/web_sc", "hn") == "/corpus/web_sc/hn.png"
    end
  end

  describe "pending/2 — the incremental capture contract" do
    setup do
      dir = Path.join(System.tmp_dir!(), "capture_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "returns every entry when the dir is empty", %{dir: dir} do
      urls = [{"a", "https://a"}, {"b", "https://b"}]
      assert Capture.pending(urls, dir) == urls
    end

    test "skips entries whose .png already exists, keeps the rest", %{dir: dir} do
      urls = [{"a", "https://a"}, {"b", "https://b"}, {"c", "https://c"}]
      File.write!(Capture.target_path(dir, "b"), "existing")

      assert Capture.pending(urls, dir) == [{"a", "https://a"}, {"c", "https://c"}]
    end

    test "returns [] once every entry is materialized", %{dir: dir} do
      urls = [{"a", "https://a"}, {"b", "https://b"}]
      for {name, _} <- urls, do: File.write!(Capture.target_path(dir, name), "x")

      assert Capture.pending(urls, dir) == []
    end
  end

  describe "cap_crop/3 — top-crop to the MP + encoder-dimension budget" do
    test "keeps an image already within budget untouched" do
      assert Capture.cap_crop(2560, 2400, 30) == :keep
    end

    test "crops a tall image to the MP budget, preserving full width" do
      # 2560×40452 ≈ 103.6 MP; cap at 30 MP.
      assert {:crop, keep_h} = Capture.cap_crop(2560, 40_452, 30)
      assert keep_h == div(30_000_000, 2560)
      assert 2560 * keep_h <= 30_000_000
      assert keep_h <= 16_383
    end

    test "caps height at the 16383 px encoder limit even when MP budget allows taller" do
      assert {:crop, 16_383} = Capture.cap_crop(1000, 50_000, 100)
    end

    test "treats the exact budget as within the cap" do
      assert Capture.cap_crop(6000, 5000, 30) == :keep
    end
  end
end

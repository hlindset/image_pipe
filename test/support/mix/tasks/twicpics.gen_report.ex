defmodule Mix.Tasks.Twicpics.GenReport do
  @shortdoc "Self-contained TwicPics differential visual-diff report (no network)"
  @moduledoc """
  Renders ImagePipe live for every constellation in `constellations.ex`, compares
  against the committed TwicPics fixtures, and writes a single self-contained
  `report.html` (images base64-inlined, slider from CDN). No network — the
  fixtures are already committed and ImagePipe renders are live.

      mise exec -- mix twicpics.gen_report [--out PATH]

  Auto-selects `MIX_ENV=test` via `mix.exs` `preferred_envs`. `--out` defaults
  to `report.html` beside the harness (gitignored).

  Renders ALL cases including triaged — quarantined divergences are the ones most
  worth eyeballing. Each card carries a QUARANTINED marker when its constellation
  has a `triage` key.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Heatmap

  alias ImagePipe.Test.TwicpicsDifferential.{
    Constellations,
    Harness,
    Manifest,
    SourceInventory,
    StructureCompare
  }

  alias ImagePipe.Test.TwicpicsDifferential.ReportHtml

  @base "test/support/image_pipe/test/twicpics_differential"
  @manifest_path "#{@base}/manifest.exs"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    out = opts[:out] || "#{@base}/report.html"
    manifest = Manifest.load!(@manifest_path)
    plug_opts = Harness.plug_opts()

    # Render ALL cases including triaged: every TwicPics chain parses (the 2 triaged
    # are divergences, not parser gaps), so they render fine — and the quarantined
    # cases are exactly the ones worth eyeballing. build_card carries `triaged?` so
    # the report can flag them.
    cards = Enum.map(Constellations.all(), &build_card(&1, manifest, plug_opts))
    File.write!(out, ReportHtml.render(%{baked_at: manifest.baked_at, cards: cards}))
    Mix.shell().info("Wrote #{length(cards)} cards to #{Path.expand(out)}")
  end

  defp build_card(c, manifest, plug_opts) do
    entry = manifest.entries[c.id]
    {body, _ct} = Harness.render(c, plug_opts)
    pipe_img = Image.open!(body, access: :random, fail_on: :error)

    pipe =
      StructureCompare.extract(
        pipe_img,
        SourceInventory.grid(Constellations.source_file(c)),
        c[:tol] || StructureCompare.default_tol()
      )

    oracle_bytes = File.read!(Harness.fixture_path(entry.fixture_filename))
    expected = %{dims: entry.dims, bands: entry.bands, cells: entry.cells}
    status = if StructureCompare.compare(expected, pipe) == :match, do: :match, else: :mismatch

    heat_banded =
      if pipe.dims == entry.dims and pipe.bands == entry.bands do
        oracle_img = Image.open!(oracle_bytes, access: :random, fail_on: :error)
        data_uri(Heatmap.png(Heatmap.banded_heatmap(oracle_img, pipe_img, 2)))
      else
        nil
      end

    %{
      id: c.id,
      verdict: c.verdict,
      group: c.group,
      status: status,
      triaged?: not is_nil(c[:triage]),
      dims_pipe: pipe.dims,
      dims_oracle: entry.dims,
      bands_pipe: pipe.bands,
      bands_oracle: entry.bands,
      cells_pipe: pipe.cells,
      cells_oracle: entry.cells,
      oracle_png: data_uri(oracle_bytes),
      pipe_png: data_uri(body),
      heat_banded: heat_banded
    }
  end

  defp data_uri(bytes), do: "data:image/png;base64,#{Base.encode64(bytes)}"
end

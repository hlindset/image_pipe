defmodule Mix.Tasks.Twicpics.Diagnose do
  @shortdoc "Structural diff of ImagePipe vs committed TwicPics records (no network)"
  @moduledoc "mix twicpics.diagnose [case_id ...] — whole suite if no ids given."
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest, SourceInventory, StructureCompare}
  @manifest_path "test/support/image_pipe/test/twicpics_differential/manifest.exs"

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    plug_opts = Harness.plug_opts()
    want = MapSet.new(args)

    Constellations.all()
    |> Enum.filter(&(is_nil(&1[:triage]) and (Enum.empty?(want) or MapSet.member?(want, &1.id))))
    |> Enum.each(fn c ->
      entry = manifest.entries[c.id]
      pipe = StructureCompare.extract(Harness.render_image(c, plug_opts), SourceInventory.grid(Constellations.source_file(c)), c[:tol] || StructureCompare.default_tol())
      expected = %{dims: entry.dims, bands: entry.bands, cells: entry.cells}

      verdict =
        case StructureCompare.compare(expected, pipe) do
          :match -> "PASS"
          {:mismatch, d} -> "MISMATCH #{inspect(d)}"
        end

      Mix.shell().info(String.pad_trailing(c.id, 32) <> "#{elem(pipe.dims, 0)}×#{elem(pipe.dims, 1)} b#{pipe.bands}  #{verdict}")
    end)
  end
end

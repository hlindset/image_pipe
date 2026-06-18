defmodule Mix.Tasks.Twicpics.Reauthor do
  @shortdoc "Refresh authored hashes after tol/verdict-only edits (no network)"
  @moduledoc "mix twicpics.reauthor — recompute authored_sha256 from constellations; no bake."
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Manifest}
  @manifest_path "test/support/image_pipe/test/twicpics_differential/manifest.exs"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), &{&1.id, &1})

    entries =
      Map.new(manifest.entries, fn {id, entry} ->
        case by_id[id] do
          nil -> Mix.raise("reauthor: entry #{id} has no constellation — re-bake to prune.")
          c -> {id, %{entry | authored_sha256: Manifest.authored_sha256(c)}}
        end
      end)

    Manifest.write!(@manifest_path, %{manifest | entries: entries})
    Mix.shell().info("Reauthored #{map_size(entries)} entries.")
  end
end

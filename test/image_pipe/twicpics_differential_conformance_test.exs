defmodule ImagePipe.TwicpicsDifferentialConformanceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest, SourceInventory, StructureCompare}

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @manifest_path "#{@base}/manifest.exs"

  setup_all do
    unless File.exists?(@manifest_path) do
      raise "No fixtures: missing #{@manifest_path}. Bootstrap: mise run twic:bake"
    end

    {:ok, manifest: Manifest.load!(@manifest_path)}
  end

  for constellation <- Constellations.all() do
    @c constellation
    if constellation[:triage], do: @tag(:twicpics_triage)

    test "#{@c.id} (#{@c.verdict}/#{@c.group})", %{manifest: manifest} do
      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed — run `mix twicpics.reauthor` (tol/verdict) or re-bake."

      pipe = StructureCompare.extract(Harness.render_image(@c), grid_spec(@c), tol(@c))
      expected = expected_record(@c, entry)

      assert StructureCompare.compare(expected, pipe) == :match,
             "#{@c.id}: structural mismatch\n  expected: #{inspect(expected)}\n  got:      #{inspect(pipe)}"
    end
  end

  test "committed sources match the manifest's recorded hashes", %{manifest: manifest} do
    for {filename, %{sha256: recorded}} <- manifest.sources do
      assert Manifest.file_sha256(Path.join(@sources_dir, filename)) == recorded,
             "source #{filename} changed since bake — restore it or re-bake (`mise run twic:bake`)."
    end
  end

  # The reference PNG is non-gating (the structural record is the gate), but the
  # manifest records its hash precisely so corruption/edits are detectable — verify
  # it, matching imgproxy's fixture-hash discipline.
  test "committed reference PNGs match the manifest's recorded hashes", %{manifest: manifest} do
    for {id, %{fixture_filename: f, fixture_sha256: recorded}} <- manifest.entries do
      path = Harness.fixture_path(f)
      assert File.exists?(path), "#{id}: missing reference PNG #{path} — re-bake (`mise run twic:bake`)."

      assert Manifest.file_sha256(path) == recorded,
             "#{id}: reference PNG #{f} sha256 mismatch — corrupted or edited; re-bake."
    end
  end

  defp grid_spec(c), do: SourceInventory.grid(Constellations.source_file(c))
  defp tol(c), do: c[:tol] || StructureCompare.default_tol()

  # :equal asserts pipe == oracle record; :diverges asserts pipe == recorded
  # ImagePipe-divergent record (oracle differs, by design).
  defp expected_record(%{verdict: :equal}, e), do: %{dims: e.dims, bands: e.bands, cells: e.cells}
  defp expected_record(%{verdict: :diverges}, e), do: e.divergence.pipe

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} -> entry
      :error -> flunk("#{id}: no manifest entry. Run: mise run twic:bake")
    end
  end
end

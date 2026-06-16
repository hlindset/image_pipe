defmodule ImagePipe.Test.TwicpicsDifferential.Manifest do
  @moduledoc """
  Generated provenance for the TwicPics differential suite (`manifest.exs`). A
  git-diffable Elixir term; machine-only (REPORT.md is the human record). Data
  crossing a serialization boundary, so `load!/1` validates shape and fails loudly.
  Serialization is delegated to `Differential.ManifestTerm`.
  """
  # Own boundary (not unbounded) so calling the `ManifestTerm` boundary doesn't trip
  # a forbidden-reference error under --warnings-as-errors — see the Task 1 boundary note.
  use Boundary, top_level?: true, check: [out: false]
  alias ImagePipe.Test.Differential.ManifestTerm

  # Authored fields whose change requires a reauthor (verdict/tol) — NOT the
  # oracle-affecting inputs (those drive the oracle signature / a re-bake).
  @authored_keys [:source, :chain, :verdict, :group, :tol, :divergence]

  @doc "Authored-field hash of a constellation (order-independent)."
  def authored_sha256(c), do: ManifestTerm.authored_sha256(c, @authored_keys)

  @doc "File-byte hash."
  defdelegate file_sha256(path), to: ManifestTerm

  @doc """
  Hash over the inputs that determine TwicPics' output: chain, pinned suffix, and
  the hosted source's byte identity. Excludes tol/verdict/group.
  """
  def oracle_signature(%{chain: chain, suffix: suffix, source_sha256: src}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({chain, suffix, src}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The incremental-bake staleness predicate: a prior entry is fresh (skip the
  oracle) only when its oracle signature still matches AND its committed PNG is
  present AND that PNG's bytes still match the recorded hash. A `nil` prior (new
  case) is never fresh. Keeps the skip decision pure and testable.
  """
  @spec fresh?(map() | nil, String.t(), Path.t()) :: boolean()
  def fresh?(nil, _sig, _path), do: false

  def fresh?(%{oracle_signature: recorded_sig, fixture_sha256: recorded_hash}, sig, path) do
    recorded_sig == sig and File.exists?(path) and file_sha256(path) == recorded_hash
  end

  @doc "Pretty-print the manifest term to `path` (mix-format stable, key-sorted)."
  def write!(path, %{} = manifest) do
    body =
      "%{" <>
        "twicpics_api: #{inspect(manifest.twicpics_api)}," <>
        "baked_at: #{inspect(manifest.baked_at)}," <>
        "sources: #{ManifestTerm.sorted_map_literal(manifest.sources)}," <>
        "entries: #{ManifestTerm.sorted_map_literal(manifest.entries)}}"

    ManifestTerm.write!(path, body)
  end

  @doc "Load + validate a manifest term."
  def load!(path) do
    {term, _binding} = Code.eval_file(path)
    validate!(term)
  end

  defp validate!(%{twicpics_api: a, baked_at: b, sources: s, entries: e} = m)
       when is_binary(a) and is_binary(b) and is_map(s) and is_map(e) do
    Enum.each(e, fn {id, entry} -> validate_entry!(id, entry) end)
    m
  end

  defp validate!(other),
    do: raise("invalid manifest: missing top-level keys in #{inspect(other, limit: 5)}")

  defp validate_entry!(_id, %{
         authored_sha256: a,
         oracle_signature: o,
         fixture_filename: f,
         fixture_sha256: fs,
         dims: {w, h},
         bands: bands,
         cells: cells
       })
       when is_binary(a) and is_binary(o) and is_binary(f) and is_binary(fs) and
              is_integer(w) and is_integer(h) and is_integer(bands) and is_list(cells),
       do: :ok

  defp validate_entry!(id, entry),
    do: raise("invalid manifest: entry #{inspect(id)} malformed: #{inspect(entry)}")
end

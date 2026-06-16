defmodule ImagePipe.Test.Differential.ManifestTerm do
  @moduledoc """
  Shared, suite-neutral serialization + hashing for differential manifests
  (imgproxy, TwicPics). Renders a git-diffable, `mix format`-stable Elixir term
  with deterministically key-sorted maps (so a manifest stays diffable past
  `inspect`'s 32-key small-map sorting limit), and computes the authored-field and
  file hashes. Each suite keeps its own `validate!`/entry shape and the top-level
  `render/1` that names its provenance fields.
  """
  use Boundary, top_level?: true, deps: []

  @doc "Pretty-print a sorted map literal string for `map` (recurses into nested maps)."
  @spec sorted_map_literal(map()) :: String.t()
  def sorted_map_literal(map) do
    body =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> pair_literal(key, value) end)

    "%{#{body}}"
  end

  defp pair_literal(key, value) when is_atom(key), do: "#{key}: #{value_literal(value)}"
  defp pair_literal(key, value), do: "#{inspect(key)} => #{value_literal(value)}"

  defp value_literal(map) when is_map(map), do: sorted_map_literal(map)
  defp value_literal(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  @doc """
  Run a full manifest body string through the real formatter and write it to
  `path` (so the committed file matches `mix format`). `body` is the suite's
  top-level `%{...}` literal built with `sorted_map_literal/1`.
  """
  @spec write!(Path.t(), String.t()) :: :ok
  def write!(path, body) when is_binary(body) do
    File.mkdir_p!(Path.dirname(path))
    formatted = body |> Code.format_string!() |> IO.iodata_to_binary()
    File.write!(path, formatted <> "\n")
  end

  @doc """
  Stable, field-order-independent hash of `keys` pulled from `term` (missing keys
  read as `nil`). Uses deterministic `term_to_binary` so nested-map values hash
  canonically across VM invocations.
  """
  @spec authored_sha256(map(), [atom()]) :: String.t()
  def authored_sha256(term, keys) do
    canonical = Enum.map(keys, fn k -> {k, Map.get(term, k)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "SHA-256 (lowercase hex) of a file's bytes."
  @spec file_sha256(Path.t()) :: String.t()
  def file_sha256(path),
    do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end

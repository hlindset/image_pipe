defmodule ImagePipe.Cache.Lookups do
  # Counts each file system cache's lookups by outcome, and the entries it
  # failed to store, since the VM started, keyed by root. Admission creates a root's counters when it first starts,
  # so they survive an Admission restart. A lookup before that isn't counted.
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.Store

  @spec ensure(Path.t()) :: :ok
  def ensure(root) do
    key = key(root)

    case :persistent_term.get(key, nil) do
      nil -> :persistent_term.put(key, :counters.new(4, [:write_concurrency]))
      _counters -> :ok
    end
  end

  @spec count(keyword(), :hit | :miss | :read_error | :write_error) :: :ok
  def count(cache_opts, outcome) do
    case :persistent_term.get(key(Store.root_dir(cache_opts)), nil) do
      nil -> :ok
      counters -> :counters.add(counters, index(outcome), 1)
    end
  end

  @spec read(Path.t()) :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          read_errors: non_neg_integer(),
          write_errors: non_neg_integer()
        }
  def read(root) do
    case :persistent_term.get(key(root), nil) do
      nil ->
        %{hits: 0, misses: 0, read_errors: 0, write_errors: 0}

      counters ->
        %{
          hits: :counters.get(counters, index(:hit)),
          misses: :counters.get(counters, index(:miss)),
          read_errors: :counters.get(counters, index(:read_error)),
          write_errors: :counters.get(counters, index(:write_error))
        }
    end
  end

  defp index(:hit), do: 1
  defp index(:miss), do: 2
  defp index(:read_error), do: 3
  defp index(:write_error), do: 4

  defp key(root), do: {__MODULE__, root}
end

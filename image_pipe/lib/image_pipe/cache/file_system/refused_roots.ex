defmodule ImagePipe.Cache.FileSystem.RefusedRoots do
  # The cache roots this node refused because another node owns them (see
  # `Owner`). Requests check it to run without those caches, so a check is
  # one ETS lookup, and adding or removing a root is one atomic write: roots
  # can change at once without a lock or a lost update.
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec refuse(Path.t()) :: :ok
  def refuse(dir) do
    :ets.insert(@table, {dir})
    :ok
  end

  @spec accept(Path.t()) :: :ok
  def accept(dir) do
    :ets.delete(@table, dir)
    :ok
  end

  @spec refused?(Path.t()) :: boolean()
  def refused?(dir), do: :ets.member(@table, dir)

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end
end

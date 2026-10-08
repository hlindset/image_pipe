defmodule ImagePipe.Cache.FileSystem.CheckedDirs do
  # Cache partition directories already found to stay under their root.
  #
  # Every lookup checks that its partition directory doesn't lead outside the
  # cache root through a symlink. A directory that passed is remembered for the
  # VM's lifetime, so later lookups skip the check. A symlink swapped in after
  # that goes unnoticed, which matters only to someone who can already write
  # inside the cache root. A failed check is never remembered.
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Without the ImagePipe application, as in a script that only reads the
  # cache, there is no table and every lookup is checked.
  @spec checked?(Path.t()) :: boolean()
  def checked?(dir), do: :ets.whereis(@table) != :undefined and :ets.member(@table, dir)

  @spec put(Path.t()) :: :ok
  def put(dir) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {dir})
    :ok
  end

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

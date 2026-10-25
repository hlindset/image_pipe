defmodule ImagePipe.Delivery.Budget do
  # What streaming sessions hold for their clients across the VM: chunks
  # buffered in memory and bytes written to spool files. A session counts
  # what it holds and gives it back when it stops. Sessions pull ahead of
  # their clients only while the VM has room. The limits are guesses, like
  # the cache writers' pending limit.
  @moduledoc false

  @limits %{memory: 256 * 1024 * 1024, spool: 2 * 1024 * 1024 * 1024}
  @index %{memory: 1, spool: 2}

  @doc "Creates the counts. Called once, when the application starts."
  def init, do: :persistent_term.put(__MODULE__, :atomics.new(2, signed: true))

  @spec add(:memory | :spool, integer()) :: :ok
  def add(_kind, 0), do: :ok
  def add(kind, bytes), do: :atomics.add(counts(), Map.fetch!(@index, kind), bytes)

  @spec held(:memory | :spool) :: integer()
  def held(kind), do: :atomics.get(counts(), Map.fetch!(@index, kind))

  @spec limit(:memory | :spool) :: pos_integer()
  def limit(kind), do: Map.fetch!(@limits, kind)

  @spec room?(:memory | :spool) :: boolean()
  def room?(kind), do: held(kind) < limit(kind)

  defp counts, do: :persistent_term.get(__MODULE__)
end

defmodule ImagePipe.Delivery.Budget do
  # What streaming sessions hold for their clients across the VM: chunks
  # buffered in memory and bytes written to spool files. A session counts
  # what it holds and gives it back when it stops. Sessions pull ahead of
  # their clients only while the VM has room. `ImagePipe.Settings` sets the
  # limits.
  @moduledoc false

  @index %{memory: 1, spool: 2}
  @limits {__MODULE__, :limits}

  @doc """
  Sets the limits, and creates the counts when the application first starts.
  A restart keeps the counts, since sessions from before it still give back
  what they hold.
  """
  @spec init(memory: non_neg_integer(), spool: non_neg_integer()) :: :ok
  def init(limits) do
    if :persistent_term.get(__MODULE__, nil) == nil,
      do: :persistent_term.put(__MODULE__, :atomics.new(2, signed: true))

    :persistent_term.put(@limits, Map.new(limits))
  end

  @spec add(:memory | :spool, integer()) :: :ok
  def add(_kind, 0), do: :ok
  def add(kind, bytes), do: :atomics.add(counts(), Map.fetch!(@index, kind), bytes)

  @spec held(:memory | :spool) :: integer()
  def held(kind), do: :atomics.get(counts(), Map.fetch!(@index, kind))

  @spec limit(:memory | :spool) :: non_neg_integer()
  def limit(kind), do: Map.fetch!(:persistent_term.get(@limits), kind)

  @spec room?(:memory | :spool) :: boolean()
  def room?(kind), do: held(kind) < limit(kind)

  defp counts, do: :persistent_term.get(__MODULE__)
end

defmodule ImagePipe.Cache.SharedFileSystem.Sources.Supervisor do
  @moduledoc false
  use Supervisor

  alias ImagePipe.Cache.SharedFileSystem.Sources

  @schema NimbleOptions.new!(
            max_entries: [type: :pos_integer, default: 256],
            max_bytes: [type: :pos_integer, default: 4 * 1024 * 1024],
            barrier_slots: [type: :pos_integer, default: 4_096],
            clock_skew: [type: :non_neg_integer, default: 5],
            max_locks: [type: :pos_integer, default: 64],
            max_waiters: [type: :non_neg_integer, default: 128],
            max_pending: [type: :pos_integer, default: 16],
            max_request_bytes: [type: :pos_integer, default: 1024 * 1024],
            clock: [type: {:fun, 0}, default: &__MODULE__.now/0]
          )

  def now, do: System.system_time(:second)

  def start_link(opts),
    do: Supervisor.start_link(__MODULE__, NimbleOptions.validate!(opts, @schema))

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    child = %{id: Sources, start: {Sources, :start_link, [table, opts]}}
    Supervisor.init([child], strategy: :one_for_one)
  end
end

defmodule ImagePipe.Cache.FileSystem.PeriodicSweep do
  # Runs a leftover sweep at start and then once every interval, so files left
  # while a node keeps running are removed without a restart. With
  # `delay_first?: true` the first sweep waits an interval too, for a pool
  # whose startup scan already sweeps. A sweep that raises is logged and runs
  # again at the next interval, so neither its failure nor a sibling's restart
  # ends the repeats.
  @moduledoc false

  use GenServer

  require Logger

  @interval_ms 24 * 60 * 60 * 1000

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    state = %{sweep: Keyword.fetch!(opts, :sweep), timer: nil}

    if Keyword.get(opts, :delay_first?, false) do
      {:ok, %{state | timer: Process.send_after(self(), :sweep, @interval_ms)}}
    else
      send(self(), :sweep)
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:sweep, %{sweep: {module, function, args}} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    try do
      apply(module, function, args)
    catch
      kind, reason ->
        Logger.error("Periodic sweep failed: " <> Exception.format(kind, reason, __STACKTRACE__))
    end

    # A sweep lists every file under the root, and an idle process doesn't
    # collect garbage, so hibernating returns that memory until the next one.
    {:noreply, %{state | timer: Process.send_after(self(), :sweep, @interval_ms)}, :hibernate}
  end
end

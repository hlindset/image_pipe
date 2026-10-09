defmodule ImagePipe.Cache.FileSystem.PeriodicSweep do
  # Runs a leftover sweep at start, or after one interval, and then once every
  # interval, so files left while a node keeps running are removed without a
  # restart. A sweep that crashes stops the repeats, as a one-shot sweep would.
  @moduledoc false

  use GenServer

  @interval_ms 24 * 60 * 60 * 1000

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    {:ok, %{sweep: Keyword.fetch!(opts, :sweep), timer: first(Keyword.fetch!(opts, :at_start?))}}
  end

  defp first(true = _at_start?) do
    send(self(), :sweep)
    nil
  end

  defp first(false = _at_start?), do: Process.send_after(self(), :sweep, @interval_ms)

  @impl GenServer
  def handle_info(:sweep, %{sweep: {module, function, args}} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    apply(module, function, args)
    {:noreply, %{state | timer: Process.send_after(self(), :sweep, @interval_ms)}}
  end
end

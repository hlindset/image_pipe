defmodule ImagePipe.Cache.Resources do
  @moduledoc false
  use GenServer

  alias ImagePipe.RawFile

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(table), do: GenServer.start_link(__MODULE__, table, name: __MODULE__)
  def track(path), do: call({:track, self(), path})

  # Hands a tracked file to `owner`, which then releases it, or leaves it to
  # be deleted when it stops.
  def transfer({token, _path}, owner), do: call({:transfer, token, owner})

  def release(:unavailable), do: :ok

  def release({token, path}) do
    RawFile.delete(path)
    call({:release, token})
    :ok
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  catch
    :exit, _reason -> :unavailable
  end

  @impl true
  def init(table) do
    monitors =
      Map.new(:ets.tab2list(table), fn {token, owner, path, _old_monitor} ->
        monitor = Process.monitor(owner)
        :ets.insert(table, {token, owner, path, monitor})
        {monitor, token}
      end)

    {:ok, %{table: table, monitors: monitors}}
  end

  @impl true
  def handle_call({:track, owner, path}, _from, state) do
    ref = Process.monitor(owner)
    :ets.insert(state.table, {ref, owner, path, ref})
    {:reply, {ref, path}, %{state | monitors: Map.put(state.monitors, ref, ref)}}
  end

  def handle_call({:transfer, token, owner}, _from, state) do
    case :ets.lookup(state.table, token) do
      [{^token, _owner, path, monitor}] ->
        Process.demonitor(monitor, [:flush])
        new_monitor = Process.monitor(owner)
        :ets.insert(state.table, {token, owner, path, new_monitor})
        monitors = state.monitors |> Map.delete(monitor) |> Map.put(new_monitor, token)
        {:reply, :ok, %{state | monitors: monitors}}

      [] ->
        {:reply, :error, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, forget(state, token)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, token} ->
        [{^token, _owner, path, _monitor}] = :ets.lookup(state.table, token)
        RawFile.delete(path)
        {:noreply, forget(state, token)}

      :error ->
        {:noreply, state}
    end
  end

  defp forget(state, token) do
    case :ets.take(state.table, token) do
      [] ->
        state

      [{^token, _owner, _path, monitor}] ->
        Process.demonitor(monitor, [:flush])
        %{state | monitors: Map.delete(state.monitors, monitor)}
    end
  end
end

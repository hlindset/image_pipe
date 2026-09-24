defmodule ImagePipe.Cache.Resources do
  @moduledoc false
  use GenServer

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(table), do: GenServer.start_link(__MODULE__, table, name: __MODULE__)
  def track(path), do: call({:track, self(), path})
  # Only completed node-local reader directories belong here. Active shared
  # writes remain with their I/O lease until their completion is known.
  def track_directory(path, timeout), do: call({:track, self(), {:directory, path}}, timeout)
  def release(handle, timeout \\ 5_000)
  def release(:unavailable, _timeout), do: :ok

  def release({token, resource}, timeout) do
    with :ok <- remove(resource) do
      call({:release, token}, timeout)
      :ok
    end
  end

  defp call(message, timeout \\ 5_000) do
    GenServer.call(__MODULE__, message, timeout)
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

  def handle_call({:release, token}, _from, state) do
    {:reply, :ok, forget(state, token)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, token} ->
        {:noreply, reclaim(state, token)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_cleanup, token}, state), do: {:noreply, reclaim(state, token)}

  defp reclaim(state, token) do
    case :ets.lookup(state.table, token) do
      [] ->
        state

      [{^token, _owner, resource, _monitor}] ->
        case remove(resource) do
          :ok ->
            forget(state, token)

          {:error, _reason} ->
            Process.send_after(self(), {:retry_cleanup, token}, 5_000)
            state
        end
    end
  end

  defp remove({:directory, path}) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp remove(path) do
    File.rm(path)
    :ok
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

defmodule ImagePipe.Cache.Resources do
  @moduledoc false
  use GenServer

  alias ImagePipe.Cache.Resources.Registration

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__.Supervisor, :start_link, [opts]}, type: :supervisor}
  end

  def start_link(table), do: GenServer.start_link(__MODULE__, table, name: __MODULE__)
  def track(path), do: Registration.claim(path)
  # Only completed node-local reader directories belong here. Active shared
  # writes remain with their I/O lease until their completion is known.
  def track_directory(_path, timeout) when timeout <= 0, do: :unavailable
  def track_directory(path, _timeout), do: Registration.claim({:directory, path})
  def release(handle, timeout \\ 5_000)
  def release(:unavailable, _timeout), do: :ok

  def release({token, resource}, _timeout) do
    with :ok <- remove(resource) do
      Registration.release(token)
    end
  end

  @impl true
  def init(table) do
    schedule()
    {:ok, reconcile(%{table: table, monitors: %{}, dead: MapSet.new()})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, token} ->
        {:noreply, reclaim(%{state | dead: MapSet.put(state.dead, token)}, token)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:tick, state) do
    state = reconcile(state)
    schedule()
    {:noreply, state}
  end

  def handle_info(:reconcile, state), do: {:noreply, reconcile(state)}

  defp schedule, do: Process.send_after(self(), :tick, 1_000)

  defp reconcile(state) do
    state =
      Enum.reduce(state.monitors, state, fn {_ref, token}, state ->
        case Registration.lookup(state.table, token) do
          nil -> forget(state, token)
          _registered -> state
        end
      end)

    watched = MapSet.new(Map.values(state.monitors))

    monitors =
      Enum.reduce(:ets.tab2list(state.table), state.monitors, fn {slot, token, owner, _},
                                                                 monitors ->
        handle = {slot, token}

        case MapSet.member?(watched, handle) do
          true -> monitors
          false -> Map.put(monitors, Process.monitor(owner), handle)
        end
      end)

    Enum.reduce(state.dead, %{state | monitors: monitors}, &reclaim(&2, &1))
  end

  defp reclaim(state, token) do
    case Registration.lookup(state.table, token) do
      nil ->
        forget(state, token)

      {_owner, resource} ->
        case remove(resource) do
          :ok ->
            Registration.release(token)
            forget(state, token)

          {:error, _reason} ->
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
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp forget(state, token) do
    monitors =
      Map.reject(state.monitors, fn {monitor, registered} ->
        case registered == token do
          true -> Process.demonitor(monitor, [:flush])
          false -> false
        end
      end)

    %{state | monitors: monitors, dead: MapSet.delete(state.dead, token)}
  end
end

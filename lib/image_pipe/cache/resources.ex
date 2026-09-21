defmodule ImagePipe.Cache.Resources do
  @moduledoc false
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def track(path), do: call({:track, self(), path})
  def release(:unavailable), do: :ok
  def release(ref), do: call({:release, ref})

  defp call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  catch
    :exit, _reason -> :unavailable
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
  @impl true
  def handle_call({:track, owner, path}, _from, state) do
    ref = Process.monitor(owner)
    {:reply, ref, Map.put(state, ref, path)}
  end

  def handle_call({:release, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, remove(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, remove(state, ref)}

  defp remove(state, ref) do
    case Map.pop(state, ref) do
      {nil, state} ->
        state

      {path, state} ->
        File.rm(path)
        state
    end
  end
end

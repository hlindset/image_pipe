defmodule ImagePipe.Cache.Work do
  @moduledoc "Node-local bounded coordination for source acquisition and background refresh."
  use GenServer
  @max_keys 64
  @max_waiters 1024
  @max_refreshes 16
  @refresh_timeout 60_000
  @backoff 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def run(key, fun) do
    case call({:lock, key}, :infinity) do
      {:ok, ref} -> locked(ref, fun)
      :busy -> fun.(false)
    end
  end

  defp locked(ref, fun) do
    fun.(ref)
  after
    call({:unlock, ref}, 5_000)
  end

  def refresh(key, fun), do: call({:refresh, key, fun}, 5_000)

  def current?(ref), do: call({:current, ref}, 5_000) == true

  def publish(key, lease, fun) do
    # Kernel owns this node-local lock, independently of this coordinator's
    # lifetime. Check the lease inside it so a replacement coordinator's
    # publication either follows the old write or excludes it entirely.
    :global.trans(
      {{__MODULE__, :publication, key}, self()},
      fn ->
        case current?(lease) do
          true -> {:ok, fun.()}
          false -> :unavailable
        end
      end,
      [node()]
    )
  end

  defp call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, _reason -> :busy
  end

  @impl true
  def init(_), do: {:ok, %{locks: %{}, refs: %{}, jobs: %{}, cooldown: %{}}}

  @impl true
  def handle_call({:lock, key}, from, state) do
    cond do
      not Map.has_key?(state.locks, key) and map_size(state.locks) >= @max_keys ->
        {:reply, :busy, state}

      Enum.reduce(state.locks, 0, fn {_key, lock}, n -> n + length(lock.waiters) end) >=
          @max_waiters ->
        {:reply, :busy, state}

      true ->
        enqueue(key, from, state)
    end
  end

  def handle_call({:unlock, ref}, _from, state), do: {:reply, :ok, release(state, ref)}

  def handle_call({:current, ref}, _from, state),
    do: {:reply, Map.has_key?(state.refs, ref), state}

  def handle_call({:refresh, key, fun}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cooldown = Map.filter(state.cooldown, fn {_key, until} -> until > now end)
    state = %{state | cooldown: cooldown}

    cond do
      Enum.any?(state.jobs, fn {_ref, job} -> job.key == key end) ->
        {:reply, :coalesced, state}

      Map.has_key?(cooldown, key) ->
        {:reply, :backoff, state}

      map_size(state.jobs) >= @max_refreshes or map_size(cooldown) >= @max_waiters ->
        {:reply, :busy, state}

      true ->
        task = Task.Supervisor.async_nolink(ImagePipe.Cache.RefreshTasks, fun)
        timer = Process.send_after(self(), {:expire, task.ref}, @refresh_timeout)
        job = %{pid: task.pid, key: key, timer: timer}
        {:reply, :started, %{state | jobs: Map.put(state.jobs, task.ref, job)}}
    end
  end

  defp enqueue(key, {pid, _tag} = from, state) do
    ref = Process.monitor(pid)
    refs = Map.put(state.refs, ref, key)

    case Map.get(state.locks, key) do
      nil ->
        lock = %{owner: ref, waiters: []}
        {:reply, {:ok, ref}, %{state | locks: Map.put(state.locks, key, lock), refs: refs}}

      lock ->
        lock = %{lock | waiters: lock.waiters ++ [{ref, from}]}
        {:noreply, %{state | locks: Map.put(state.locks, key, lock), refs: refs}}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref),
    do: {:noreply, finish_job(state, ref)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, state |> release(ref) |> finish_job(ref)}
  end

  def handle_info({:expire, ref}, state) do
    case Map.get(state.jobs, ref) do
      nil -> :ok
      job -> Process.exit(job.pid, :kill)
    end

    {:noreply, state}
  end

  defp finish_job(state, ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _jobs} ->
        state

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(job.timer)

        %{
          state
          | jobs: jobs,
            cooldown:
              Map.put(state.cooldown, job.key, System.monotonic_time(:millisecond) + @backoff)
        }
    end
  end

  defp release(state, ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.refs, ref) do
      {nil, _refs} -> state
      {key, refs} -> release_lock(%{state | refs: refs}, key, ref)
    end
  end

  defp release_lock(state, key, ref) do
    case Map.fetch!(state.locks, key) do
      %{owner: ^ref, waiters: []} ->
        %{state | locks: Map.delete(state.locks, key)}

      %{owner: ^ref, waiters: [{next, from} | rest]} ->
        GenServer.reply(from, {:ok, next})
        %{state | locks: Map.put(state.locks, key, %{owner: next, waiters: rest})}

      lock ->
        lock = %{
          lock
          | waiters: Enum.reject(lock.waiters, fn {waiter, _from} -> waiter == ref end)
        }

        %{state | locks: Map.put(state.locks, key, lock)}
    end
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end

defmodule ImagePipe.Cache.Work do
  # Node-local bounded coordination for source acquisition and background refresh.
  @moduledoc false
  use GenServer
  alias ImagePipe.Telemetry
  # A lock holds no CPU while it waits on the origin, only a map entry and a
  # monitor, so it allows many more keys than `Cache.OutputWork` allows images.
  @max_keys 4096
  @max_waiters 1024
  @max_refreshes 16
  @refresh_timeout 60_000
  @backoff 1_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # `fun` gets the lease, or `false` without one, and how it got the key:
  # `:acquired`, `:coalesced` after waiting behind another holder, `:bypass`
  # when the holder found it had nothing to share (`release_waiters/1`), or
  # `:busy`.
  # `wait:` bounds how long to wait behind another holder of the key, after
  # which the work doesn't run and `run/3` returns `:timeout`.
  # `share:` identifies requests eligible for the owner's explicit completion.
  def run(key, fun, opts \\ []) do
    case lock(key, Keyword.get(opts, :wait, :infinity), Keyword.get(opts, :share)) do
      {:ok, ref, outcome} ->
        report(outcome, :source, opts)
        locked(ref, outcome, fun)

      {:shared, value} ->
        report(:coalesced, :source, opts)
        value

      :bypass ->
        report(:bypass, :source, opts, %{reason: :not_stored})
        fun.(false, :bypass)

      :timeout ->
        report(:timeout, :source, opts)
        :timeout

      :busy ->
        report(:busy, :source, opts)
        fun.(false, :busy)
    end
  end

  defp lock(key, wait, context) do
    request = :gen_server.send_request(__MODULE__, {:lock, key, context})

    # `wait_response/2`, unlike `receive_response/2`, keeps the request open
    # when the wait runs out, so `cancel_wait/2` can still receive a grant.
    case :gen_server.wait_response(request, wait) do
      {:reply, reply} -> reply
      :timeout -> cancel_wait(key, request)
      {:error, _reason} -> :busy
    end
  end

  # The coordinator releases a lock it granted after the wait ran out when it
  # handles the cancellation. `receive_response/2` closes the request and
  # drops that grant's reply.
  defp cancel_wait(key, request) do
    _result = call({:cancel_wait, key}, 5_000)
    _reply = :gen_server.receive_response(request, 0)
    :timeout
  end

  defp locked(ref, outcome, fun) do
    fun.(ref, outcome)
  after
    call({:unlock, ref}, 5_000)
  end

  # Completion releases this lease and hands a resource-free value only to
  # matching requests already queued. Nothing is retained for later arrivals.
  def complete(ref, value), do: call({:complete, ref, value}, 5_000)

  # The processes of the queued requests `complete_each/2` can answer: those
  # whose `share:` matches the holder's.
  def sharing(ref) do
    case call({:sharing, ref}, 5_000) do
      pids when is_list(pids) -> pids
      :busy -> []
    end
  end

  # Like `complete/2`, with a value of its own for each waiting process in
  # `values`, such as a resource handed to it. A matching request that isn't
  # in `values` stays queued.
  def complete_each(ref, values), do: call({:complete_each, ref, values}, 5_000)

  # The holder of `ref` found that its work will store nothing, so the
  # requests waiting for it go ahead on their own, without a lease, and the
  # key is free for later arrivals. The holder's lease is no longer current.
  def release_waiters(ref), do: call({:release_waiters, ref}, 5_000)

  def refresh(key, fun, opts \\ []) do
    result = call({:refresh, key, fun}, 5_000)
    report(result, :refresh, opts)
    result
  end

  defp report(result, operation, opts, metadata \\ %{}) do
    Telemetry.execute(
      opts,
      [:cache, :coordination],
      %{},
      Map.merge(%{pool: :input, result: result, operation: operation}, metadata)
    )
  end

  def current?(ref), do: call({:current, ref}, 5_000) == true

  # Work that ran without a lease, because the coordinator was busy or
  # unavailable, or because nothing it leaves is shared, publishes without
  # the lock. Its writes are single writes to memory, ordered against a
  # leased publication by when they land, as they would be by the lock.
  # Waiting for the lock would cost the request `:global`'s retry sleeps.
  def publish(_key, nil, fun), do: {:ok, fun.()}

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
  def handle_call({:lock, key, context}, from, state) do
    cond do
      not Map.has_key?(state.locks, key) and map_size(state.locks) >= @max_keys ->
        {:reply, :busy, state}

      waiters(state) >= @max_waiters ->
        {:reply, :busy, state}

      true ->
        enqueue(key, from, context, state)
    end
  end

  def handle_call({:unlock, ref}, _from, state), do: {:reply, :ok, release(state, ref)}

  def handle_call({:complete, ref, value}, _from, state) do
    {:reply, :ok, complete_cohort(state, ref, fn _pid -> {:ok, value} end)}
  end

  def handle_call({:sharing, ref}, _from, state) do
    pids =
      with {:ok, key} <- Map.fetch(state.refs, ref),
           %{owner: ^ref} = lock <- Map.fetch!(state.locks, key) do
        for {_ref, {pid, _tag}, context} <- lock.waiters,
            lock.context != nil and context == lock.context,
            do: pid
      else
        _ -> []
      end

    {:reply, pids, state}
  end

  def handle_call({:complete_each, ref, values}, _from, state) do
    {:reply, :ok, complete_cohort(state, ref, &Map.fetch(values, &1))}
  end

  def handle_call({:release_waiters, ref}, _from, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, key} ->
        %{owner: ^ref} = lock = Map.fetch!(state.locks, key)

        released =
          Enum.map(lock.waiters, fn {waiter, from, _context} ->
            Process.demonitor(waiter, [:flush])
            GenServer.reply(from, :bypass)
            waiter
          end)

        state = %{
          state
          | refs: Map.drop(state.refs, released),
            locks: Map.put(state.locks, key, %{lock | waiters: []})
        }

        {:reply, :ok, release(state, ref)}

      :error ->
        {:reply, :ok, state}
    end
  end

  # A waiter cancels after its wait ran out, so it goes on without the lock.
  # A lock handed to it from the queue meanwhile is released too: when the
  # cancel itself timed out, the waiter never reads the grant.
  def handle_call({:cancel_wait, key}, {pid, _tag}, state) do
    refs =
      case Map.get(state.locks, key) do
        nil ->
          []

        lock ->
          waiting = for {ref, {^pid, _tag}, _context} <- lock.waiters, do: ref
          if lock.granted_to == pid, do: waiting ++ [lock.owner], else: waiting
      end

    {:reply, :ok, Enum.reduce(refs, state, &release(&2, &1))}
  end

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

  # Every lock's owner and every waiter holds a monitor in `refs`.
  defp waiters(state), do: map_size(state.refs) - map_size(state.locks)

  defp enqueue(key, {pid, _tag} = from, context, state) do
    ref = Process.monitor(pid)
    refs = Map.put(state.refs, ref, key)

    case Map.get(state.locks, key) do
      nil ->
        lock = %{owner: ref, granted_to: nil, context: context, waiters: []}

        {:reply, {:ok, ref, :acquired},
         %{state | locks: Map.put(state.locks, key, lock), refs: refs}}

      lock ->
        lock = %{lock | waiters: lock.waiters ++ [{ref, from, context}]}
        {:noreply, %{state | locks: Map.put(state.locks, key, lock), refs: refs}}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref),
    do: {:noreply, finish_job(state, ref)}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state),
    do: {:noreply, state |> release(monitor) |> finish_job(monitor)}

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

  # `value` gives each matching waiter's process `{:ok, value}`, or `:error`
  # to leave it queued.
  defp complete_cohort(state, ref, value) do
    case Map.fetch(state.refs, ref) do
      :error ->
        state

      {:ok, key} ->
        %{owner: ^ref} = lock = Map.fetch!(state.locks, key)

        {shared, waiters} =
          Enum.split_with(lock.waiters, fn {_ref, {pid, _tag}, context} ->
            lock.context != nil and context == lock.context and value.(pid) != :error
          end)

        shared_refs =
          Enum.map(shared, fn {waiter, {pid, _tag} = from, _context} ->
            {:ok, shared} = value.(pid)
            Process.demonitor(waiter, [:flush])
            GenServer.reply(from, {:shared, shared})
            waiter
          end)

        state = %{
          state
          | refs: Map.drop(state.refs, shared_refs),
            locks: Map.put(state.locks, key, %{lock | waiters: waiters})
        }

        release(state, ref)
    end
  end

  defp release_lock(state, key, ref) do
    case Map.fetch!(state.locks, key) do
      %{owner: ^ref, waiters: []} ->
        %{state | locks: Map.delete(state.locks, key)}

      %{owner: ^ref, waiters: [{next, {pid, _tag} = from, context} | rest]} ->
        GenServer.reply(from, {:ok, next, :coalesced})
        lock = %{owner: next, granted_to: pid, context: context, waiters: rest}
        %{state | locks: Map.put(state.locks, key, lock)}

      lock ->
        lock = %{
          lock
          | waiters: Enum.reject(lock.waiters, fn {waiter, _from, _context} -> waiter == ref end)
        }

        %{state | locks: Map.put(state.locks, key, lock)}
    end
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end

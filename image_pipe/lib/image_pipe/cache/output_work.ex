defmodule ImagePipe.Cache.OutputWork do
  # Single-flight leases for generating a processed image. The first request
  # for a key leads, and the others wait for it to complete the lease, or for
  # it to stop. A follower (`follow/3`) waits on a flight but never leads one:
  # without a flight it gets `:none`, and it's never promoted when a leader
  # stops. A lease belongs to one process at a time: only the owner
  # completes it, so a request that handed its lease to a stream or a cache
  # writer can't complete it early. A lease handed off with a deadline
  # releases its waiters with `:bypass` when the deadline passes first.
  @moduledoc false
  use GenServer

  alias ImagePipe.Telemetry

  @max_flights 64
  @max_waiters 1024
  @wait_timeout 60_000

  @type lease :: {GenServer.server(), reference()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def join(cache, key, opts, timeout \\ @wait_timeout) do
    result = call(__MODULE__, {:join, {cache, key}, timeout, true}, :infinity)
    joined(result, opts)
  end

  def follow(cache, key, opts) do
    case call(__MODULE__, {:join, {cache, key}, @wait_timeout, false}, :infinity) do
      :none -> :none
      result -> joined(result, opts)
    end
  end

  defp joined({:waiting, {server, token}}, opts) do
    report(opts, :waiting)
    monitor = Process.monitor(server)

    result =
      receive do
        {^token, result} -> result
        {:DOWN, ^monitor, :process, ^server, _reason} -> :bypass
      end

    Process.demonitor(monitor, [:flush])
    joined(result, opts)
  end

  defp joined({:leader, _lease} = result, opts) do
    report(opts, :acquired)
    result
  end

  defp joined(:busy, opts) do
    report(opts, :busy)
    :bypass
  end

  defp joined({:bypass, reason} = result, opts) do
    report(opts, :bypass, %{reason: reason})
    result
  end

  defp joined(result, opts) do
    report(opts, result)
    result
  end

  def transfer(lease), do: transfer(lease, self(), nil)

  def transfer(nil, _owner, _deadline), do: :ok

  def transfer({server, token}, owner, deadline),
    do: call(server, {:transfer, token, owner, deadline})

  def complete(nil, _result), do: :ok
  def complete({server, token}, result), do: call(server, {:complete, token, result})

  defp call(server, message, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _reason -> :bypass
  end

  @impl true
  def init(_opts), do: {:ok, %{flights: %{}, members: %{}, monitors: %{}}}

  @impl true
  def handle_call({:join, key, timeout, lead?}, from, state) do
    cond do
      not lead? and not Map.has_key?(state.flights, key) ->
        {:reply, :none, state}

      not Map.has_key?(state.flights, key) and map_size(state.flights) >= @max_flights ->
        {:reply, :busy, state}

      map_size(state.members) - map_size(state.flights) >= @max_waiters ->
        {:reply, :busy, state}

      true ->
        join_flight(state, key, from, timeout, lead?)
    end
  end

  def handle_call({:transfer, token, owner, deadline}, _from, state) do
    case Map.fetch(state.members, token) do
      {:ok, member} ->
        Process.demonitor(member.monitor, [:flush])
        if deadline, do: Process.send_after(self(), {:deadline, token}, deadline)
        monitor = Process.monitor(owner)
        monitors = state.monitors |> Map.delete(member.monitor) |> Map.put(monitor, token)
        member = %{member | monitor: monitor, owner: owner}
        {:reply, :ok, %{put_in(state.members[token], member) | monitors: monitors}}

      :error ->
        {:reply, :bypass, state}
    end
  end

  def handle_call({:complete, token, result}, {caller, _tag}, state) do
    case Map.fetch(state.members, token) do
      {:ok, %{key: key, owner: ^caller}} ->
        %{owner: ^token, waiters: waiters} = Map.fetch!(state.flights, key)
        state = Enum.reduce(waiters, state, &reply_and_remove(&2, &1, result))
        {:reply, :ok, state |> remove(token) |> delete_flight(key)}

      _completed_or_handed_off ->
        {:reply, :ok, state}
    end
  end

  defp join_flight(state, key, {pid, _tag}, timeout, lead?) do
    token = make_ref()
    monitor = Process.monitor(pid)
    state = put_in(state.monitors[monitor], token)

    member = %{
      key: key,
      lead?: lead?,
      owner: pid,
      monitor: monitor,
      from: {pid, token},
      timer: nil,
      deadline: nil
    }

    case Map.fetch(state.flights, key) do
      :error ->
        state = put_in(state.members[token], member)

        {:reply, {:leader, {self(), token}},
         put_in(state.flights[key], %{owner: token, waiters: []})}

      {:ok, flight} ->
        timer = Process.send_after(self(), {:expire, token}, timeout)
        member = %{member | timer: timer, deadline: System.monotonic_time(:millisecond) + timeout}
        state = put_in(state.members[token], member)
        state = put_in(state.flights[key], %{flight | waiters: flight.waiters ++ [token]})
        {:reply, {:waiting, {self(), token}}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor) do
      {:ok, token} ->
        %{key: key} = Map.fetch!(state.members, token)
        flight = Map.fetch!(state.flights, key)
        state = remove(state, token)

        case flight.owner do
          ^token ->
            {:noreply, promote(state, key, flight.waiters)}

          _owner ->
            {:noreply, put_in(state.flights[key].waiters, List.delete(flight.waiters, token))}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:deadline, token}, state) do
    case Map.fetch(state.members, token) do
      {:ok, %{key: key}} ->
        %{owner: ^token, waiters: waiters} = Map.fetch!(state.flights, key)
        state = Enum.reduce(waiters, state, &reply_and_remove(&2, &1, {:bypass, :deadline}))
        {:noreply, state |> remove(token) |> delete_flight(key)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:expire, token}, state) do
    case Map.fetch(state.members, token) do
      {:ok, %{key: key, timer: timer}} when not is_nil(timer) ->
        waiters = List.delete(state.flights[key].waiters, token)
        state = reply_and_remove(state, token, :bypass)
        {:noreply, put_in(state.flights[key].waiters, waiters)}

      _expired_or_promoted ->
        {:noreply, state}
    end
  end

  # Promotes the first waiter that may lead and hasn't expired. Followers
  # ahead of it keep waiting on the new leader. With no waiter to promote, the
  # remaining followers bypass.
  defp promote(state, key, waiters, followers \\ [])

  defp promote(state, key, [], followers) do
    followers
    |> Enum.reverse()
    |> Enum.reduce(state, &reply_and_remove(&2, &1, :bypass))
    |> delete_flight(key)
  end

  defp promote(state, key, [token | rest], followers) do
    member = Map.fetch!(state.members, token)

    cond do
      not member.lead? ->
        promote(state, key, rest, [token | followers])

      member.deadline > System.monotonic_time(:millisecond) ->
        Process.cancel_timer(member.timer)
        GenServer.reply(member.from, {:leader, {self(), token}})
        state = put_in(state.members[token], %{member | timer: nil, deadline: nil})
        put_in(state.flights[key], %{owner: token, waiters: Enum.reverse(followers, rest)})

      true ->
        state |> reply_and_remove(token, :bypass) |> promote(key, rest, followers)
    end
  end

  defp reply_and_remove(state, token, result) do
    member = Map.fetch!(state.members, token)
    GenServer.reply(member.from, result)
    remove(state, token)
  end

  defp remove(state, token) do
    {member, members} = Map.pop!(state.members, token)
    Process.demonitor(member.monitor, [:flush])
    if member.timer, do: Process.cancel_timer(member.timer)
    %{state | members: members, monitors: Map.delete(state.monitors, member.monitor)}
  end

  defp delete_flight(state, key), do: %{state | flights: Map.delete(state.flights, key)}

  defp report(opts, result, extra \\ %{}) do
    Telemetry.execute(
      opts,
      [:cache, :coordination],
      %{},
      Map.merge(%{pool: :output, operation: :output, result: result}, extra)
    )
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end

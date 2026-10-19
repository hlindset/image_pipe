defmodule ImagePipe.Cache.OutputWork do
  # Single-flight leases for generating a processed image. The first request
  # for a key leads, and the others wait for it to complete the lease, or for
  # it to stop. A follower (`follow/4`) waits on a flight but never leads one:
  # without a flight it gets `:none`, and it's never promoted when a leader
  # stops. A lease belongs to one process at a time: only the owner
  # completes it, so a request that handed its lease to a stream or a cache
  # writer can't complete it early. A lease handed off with a deadline
  # releases its waiters with `:bypass` when the deadline passes first.
  #
  # A second instance holds the flights of identical requests waiting for one
  # original's download (`join_download/4`), so they don't take the image
  # flights' slots, and report as the `:download` operation and pool.
  @moduledoc false
  use GenServer

  alias ImagePipe.Telemetry

  @max_keys 64
  @max_waiters 1024
  @wait_timeout 60_000

  @downloads ImagePipe.Cache.OutputWork.Downloads

  @type lease :: {GenServer.server(), reference()}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  # `timeout` bounds the wait, `nil` for the default.
  def join(cache, key, opts, timeout \\ nil),
    do: join_on({__MODULE__, :output}, cache, key, opts, timeout)

  def follow(cache, key, opts, timeout \\ nil),
    do: follow_on({__MODULE__, :output}, cache, key, opts, timeout)

  def join_download(cache, key, opts, timeout \\ nil),
    do: join_on({@downloads, :download}, cache, key, opts, timeout)

  def follow_download(cache, key, opts, timeout \\ nil),
    do: follow_on({@downloads, :download}, cache, key, opts, timeout)

  defp join_on({server, _operation} = flights, cache, key, opts, timeout) do
    result = call(server, {:join, {cache, key}, timeout || @wait_timeout, true}, :infinity)
    joined(result, flights, opts)
  end

  defp follow_on({server, _operation} = flights, cache, key, opts, timeout) do
    case call(server, {:join, {cache, key}, timeout || @wait_timeout, false}, :infinity) do
      :none -> :none
      result -> joined(result, flights, opts)
    end
  end

  defp joined({:waiting, {server, token}}, flights, opts) do
    report(opts, flights, :waiting)
    monitor = Process.monitor(server)

    result =
      receive do
        {^token, result} -> result
        {:DOWN, ^monitor, :process, ^server, _reason} -> :bypass
      end

    Process.demonitor(monitor, [:flush])
    joined(result, flights, opts)
  end

  defp joined({:leader, _lease} = result, flights, opts) do
    report(opts, flights, :acquired)
    result
  end

  defp joined(:busy, flights, opts) do
    report(opts, flights, :busy)
    :bypass
  end

  # A leader may hand its waiters what it learned along with `:ready`.
  defp joined({:ready, _value} = result, flights, opts) do
    report(opts, flights, :ready)
    result
  end

  defp joined({:bypass, reason} = result, flights, opts) do
    report(opts, flights, :bypass, %{reason: reason})
    result
  end

  defp joined(result, flights, opts) do
    report(opts, flights, result)
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
  def init(_opts), do: {:ok, %{flights: %{}, members: %{}}}

  @impl true
  def handle_call({:join, key, timeout, lead?}, from, state) do
    cond do
      not lead? and not Map.has_key?(state.flights, key) ->
        {:reply, :none, state}

      not Map.has_key?(state.flights, key) and map_size(state.flights) >= @max_keys ->
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
        member = %{member | monitor: Process.monitor(owner), owner: owner}
        {:reply, :ok, put_in(state.members[token], member)}

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

    member = %{
      key: key,
      lead?: lead?,
      owner: pid,
      monitor: Process.monitor(pid),
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
    case Enum.find(state.members, fn {_token, member} -> member.monitor == monitor end) do
      {token, %{key: key}} ->
        flight = Map.fetch!(state.flights, key)
        state = remove(state, token)

        case flight.owner do
          ^token ->
            {:noreply, promote(state, key, flight.waiters)}

          _owner ->
            {:noreply, put_in(state.flights[key].waiters, List.delete(flight.waiters, token))}
        end

      nil ->
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
    %{state | members: members}
  end

  defp delete_flight(state, key), do: %{state | flights: Map.delete(state.flights, key)}

  defp pool(:download), do: :download
  defp pool(:output), do: :output

  defp report(opts, {_server, operation}, result, extra \\ %{}) do
    Telemetry.execute(
      opts,
      [:cache, :coordination],
      %{},
      Map.merge(%{pool: pool(operation), operation: operation, result: result}, extra)
    )
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end

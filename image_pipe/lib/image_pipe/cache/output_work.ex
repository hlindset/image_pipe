defmodule ImagePipe.Cache.OutputWork do
  @moduledoc false
  use GenServer

  alias ImagePipe.Telemetry

  @max_keys 64
  @max_waiters 1024
  @wait_timeout 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def join(cache, key, opts, timeout \\ @wait_timeout) do
    result = call(__MODULE__, {:join, {cache, key}, timeout}, :infinity)
    joined(result, opts)
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

  defp joined(result, opts) do
    report(opts, result)
    result
  end

  def transfer(nil), do: :ok
  def transfer({server, token}), do: call(server, {:transfer, token, self()})

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
  def handle_call({:join, key, timeout}, from, state) do
    cond do
      not Map.has_key?(state.flights, key) and map_size(state.flights) >= @max_keys ->
        {:reply, :busy, state}

      map_size(state.members) - map_size(state.flights) >= @max_waiters ->
        {:reply, :busy, state}

      true ->
        join_flight(state, key, from, timeout)
    end
  end

  def handle_call({:transfer, token, owner}, _from, state) do
    case Map.fetch(state.members, token) do
      {:ok, member} ->
        Process.demonitor(member.monitor, [:flush])
        member = %{member | monitor: Process.monitor(owner)}
        {:reply, :ok, put_in(state.members[token], member)}

      :error ->
        {:reply, :bypass, state}
    end
  end

  def handle_call({:complete, token, result}, _from, state) do
    case Map.fetch(state.members, token) do
      {:ok, %{key: key}} ->
        %{owner: ^token, waiters: waiters} = Map.fetch!(state.flights, key)
        state = Enum.reduce(waiters, state, &reply_and_remove(&2, &1, result))
        {:reply, :ok, state |> remove(token) |> delete_flight(key)}

      :error ->
        {:reply, :ok, state}
    end
  end

  defp join_flight(state, key, {pid, _tag}, timeout) do
    token = make_ref()

    member = %{
      key: key,
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

  defp promote(state, key, []), do: delete_flight(state, key)

  defp promote(state, key, [token | rest]) do
    member = Map.fetch!(state.members, token)

    case member.deadline > System.monotonic_time(:millisecond) do
      true ->
        Process.cancel_timer(member.timer)
        GenServer.reply(member.from, {:leader, {self(), token}})
        state = put_in(state.members[token], %{member | timer: nil, deadline: nil})
        put_in(state.flights[key], %{owner: token, waiters: rest})

      false ->
        state |> reply_and_remove(token, :bypass) |> promote(key, rest)
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

  defp report(opts, result) do
    Telemetry.execute(opts, [:cache, :coordination], %{}, %{
      pool: :output,
      operation: :output,
      result: result
    })
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}
end

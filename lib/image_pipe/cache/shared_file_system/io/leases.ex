defmodule ImagePipe.Cache.SharedFileSystem.IO.Leases do
  @moduledoc false

  def new(count, bytes), do: %{entries: %{}, bytes: 0, max_count: count, max_bytes: bytes}

  def reserve(state, owner, bytes, cleanup, timeout) do
    case map_size(state.entries) < state.max_count and state.bytes + bytes <= state.max_bytes do
      true ->
        token = Process.monitor(owner)
        timer = Process.send_after(self(), {:offer_expired, token}, timeout)
        entry = %{bytes: bytes, cleanup: cleanup, status: :offered, waiter: nil, timer: timer}

        {{:ok, token},
         %{state | entries: Map.put(state.entries, token, entry), bytes: state.bytes + bytes}}

      false ->
        {{:error, :saturated}, state}
    end
  end

  def accept(state, token) do
    case Map.get(state.entries, token) do
      %{status: :offered} = entry ->
        Process.cancel_timer(entry.timer)
        put(state, token, %{entry | status: :open, timer: nil})

      _missing_or_closed ->
        state
    end
  end

  def expire(state, token) do
    case Map.get(state.entries, token) do
      %{status: :offered} -> owner_down(state, token)
      _entry -> state
    end
  end

  def open?(_state, nil), do: true
  def open?(state, token), do: match?(%{status: :open}, Map.get(state.entries, token))

  def close(state, token, from) do
    case Map.get(state.entries, token) do
      nil ->
        {:error, :released}

      %{waiter: nil} = entry ->
        status = closing_status(entry.status)
        {:ok, put(state, token, %{entry | status: status, waiter: from})}

      _entry ->
        {:error, :closing}
    end
  end

  def owner_down(state, token) do
    case Map.get(state.entries, token) do
      nil ->
        state

      entry ->
        cancel_timer(entry.timer)

        put(state, token, %{entry | status: closing_status(entry.status), waiter: nil, timer: nil})
    end
  end

  def ready(state, active, count) do
    candidates =
      state.entries
      |> Enum.filter(fn {token, entry} ->
        entry.status == :closing and not MapSet.member?(active, token)
      end)
      |> Enum.take(count)

    operations = Enum.map(candidates, fn {token, entry} -> {token, entry.cleanup} end)

    state =
      Enum.reduce(candidates, state, fn {token, entry}, state ->
        put(state, token, %{entry | status: :cleaning})
      end)

    {operations, state}
  end

  def complete(state, token, {:ok, :ok}) do
    {entry, entries} = Map.pop!(state.entries, token)
    Process.demonitor(token, [:flush])
    cancel_timer(entry.timer)
    reply(entry.waiter, :ok)
    %{state | entries: entries, bytes: state.bytes - entry.bytes}
  end

  def complete(state, token, result) do
    entry = Map.fetch!(state.entries, token)
    reply(entry.waiter, {:error, {:cleanup, result}})
    put(state, token, %{entry | status: :failed, waiter: nil})
  end

  def retry(state) do
    entries =
      Map.new(state.entries, fn
        {token, %{status: :failed} = entry} -> {token, %{entry | status: :closing}}
        item -> item
      end)

    %{state | entries: entries}
  end

  def unavailable(state) do
    entries =
      Map.new(state.entries, fn {token, entry} ->
        reply(entry.waiter, {:error, :unavailable})
        {token, %{entry | waiter: nil}}
      end)

    %{state | entries: entries}
  end

  defp put(state, token, entry), do: %{state | entries: Map.put(state.entries, token, entry)}
  defp closing_status(:cleaning), do: :cleaning
  defp closing_status(_status), do: :closing
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)
  defp reply(nil, _result), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)
end

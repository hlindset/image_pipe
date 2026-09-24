defmodule ImagePipe.Cache.SharedFileSystem.IO.Admission do
  @moduledoc false

  def new(count, bytes) do
    %{
      table: :ets.new(__MODULE__, [:set, :public]),
      disabled: :atomics.new(1, []),
      count: count,
      bytes: bytes
    }
  end

  def claim(gate, request) do
    cond do
      :atomics.get(gate.disabled, 1) == 1 -> {:error, :unavailable}
      :erlang.external_size(request) > gate.bytes -> {:error, :saturated}
      true -> claim_slot(gate, 1, make_ref())
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  def release(gate, {slot, token}) do
    :ets.match_delete(gate.table, {slot, token, :_})
  end

  def disable(gate), do: :atomics.put(gate.disabled, 1, 1)

  def watch(gate, monitors) do
    Enum.reduce(:ets.tab2list(gate.table), monitors, fn {slot, token, owner}, monitors ->
      ticket = {slot, token}

      case ticket in Map.values(monitors) do
        true -> monitors
        false -> Map.put(monitors, Process.monitor(owner), ticket)
      end
    end)
  end

  def forget(monitors, ticket) do
    case Enum.find(monitors, fn {_ref, pending} -> pending == ticket end) do
      nil ->
        monitors

      {ref, _ticket} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, ref)
    end
  end

  defp claim_slot(gate, slot, _token) when slot > gate.count, do: {:error, :saturated}

  defp claim_slot(gate, slot, token) do
    case :ets.insert_new(gate.table, {slot, token, self()}) do
      true -> {:ok, {slot, token}}
      false -> claim_slot(gate, slot + 1, token)
    end
  end
end

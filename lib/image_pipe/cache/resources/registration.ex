defmodule ImagePipe.Cache.Resources.Registration do
  @moduledoc false

  @capacity 1_024
  @max_payload_bytes 8_192

  def new do
    :ets.new(__MODULE__, [:named_table, :set, :public, read_concurrency: true])
  end

  def claim(resource) do
    case :erlang.external_size(resource) <= @max_payload_bytes do
      true -> claim(resource, 1, make_ref())
      false -> :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  def lookup(table, {slot, token}) do
    case :ets.lookup(table, slot) do
      [{^slot, ^token, owner, resource}] -> {owner, resource}
      _missing -> nil
    end
  end

  def release({slot, token}) do
    :ets.match_delete(__MODULE__, {slot, token, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp claim(_resource, slot, _token) when slot > @capacity, do: :unavailable

  defp claim(resource, slot, token) do
    case :ets.insert_new(__MODULE__, {slot, token, self(), resource}) do
      true -> {{slot, token}, resource}
      false -> claim(resource, slot + 1, token)
    end
  end
end

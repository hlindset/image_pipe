defmodule ImagePipe.API.Signature.Keys do
  @moduledoc false

  @enforce_keys [:values]
  @derive {Inspect, except: [:values]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{values: [binary()]}

  def new!(keys) when is_list(keys), do: %__MODULE__{values: Enum.map(keys, &decode!/1)}
  def new!(_keys), do: invalid!()

  defp decode!(key) when is_binary(key) and key != "" do
    case Base.decode16(key, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> invalid!()
    end
  end

  defp decode!(_key), do: invalid!()
  defp invalid!, do: raise(ArgumentError, "invalid ImagePipe.API signing keys")
end

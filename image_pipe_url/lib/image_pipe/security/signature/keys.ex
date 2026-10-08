defmodule ImagePipe.Security.Signature.Keys do
  @moduledoc false

  @enforce_keys [:values]
  @derive {Inspect, except: [:values]}
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{values: [binary()]}

  def new!(keys), do: %__MODULE__{values: Enum.map(keys, &decode!/1)}

  # A short HMAC key can be brute-forced offline from one signed URL.
  @min_bytes 32

  defp decode!(key) when is_binary(key) do
    case Base.decode16(key, case: :mixed) do
      {:ok, decoded} when byte_size(decoded) >= @min_bytes -> decoded
      _invalid -> invalid!()
    end
  end

  defp decode!(_key), do: invalid!()

  defp invalid!,
    do:
      raise(
        ArgumentError,
        "signing keys must be a list of hex strings of at least #{@min_bytes * 2} digits (#{@min_bytes} bytes)"
      )
end

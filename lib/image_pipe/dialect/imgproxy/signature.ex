defmodule ImagePipe.Dialect.Imgproxy.Signature do
  @moduledoc false

  @signature_schema NimbleOptions.new!(
                      keys: [type: {:list, :string}, default: []],
                      salts: [type: {:list, :string}, default: []],
                      signature_size: [type: :integer, default: 32],
                      trusted_signatures: [
                        type: {:custom, __MODULE__, :validate_trusted_signatures, []},
                        default: []
                      ]
                    )

  @enforce_keys [:mode, :key_salt_pairs, :signature_size, :trusted_signatures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :disabled | :enabled,
          key_salt_pairs: [{binary(), binary()}],
          signature_size: 1..32,
          trusted_signatures: MapSet.t(String.t())
        }

  @spec disabled() :: t()
  def disabled do
    %__MODULE__{
      mode: :disabled,
      key_salt_pairs: [],
      signature_size: 32,
      trusted_signatures: MapSet.new()
    }
  end

  @spec verify(String.t(), binary(), t()) :: :ok | {:error, term()}
  def verify(signature, _signed_path, %__MODULE__{mode: :disabled})
      when signature in ["_", "unsafe"],
      do: :ok

  def verify(signature, _signed_path, %__MODULE__{mode: :disabled}),
    do: {:error, {:unsupported_signature, signature}}

  def verify(signature, signed_path, %__MODULE__{mode: :enabled} = config) do
    case trusted_signature?(signature, config.trusted_signatures) do
      true -> :ok
      false -> verify_hmac_signature(signature, signed_path, config)
    end
  end

  @doc false
  def validate_trusted_signatures(values) when is_list(values) do
    case Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, values}
      false -> {:error, "trusted_signatures must be a list of non-empty strings"}
    end
  end

  def validate_trusted_signatures(_values),
    do: {:error, "trusted_signatures must be a list of non-empty strings"}

  defp trusted_signature?(signature, trusted_signatures) do
    Enum.any?(trusted_signatures, &same_signature?(&1, signature))
  end

  defp same_signature?(left, right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp verify_hmac_signature(signature, signed_path, %__MODULE__{} = config) do
    with :ok <- validate_encoded_signature_size(signature, config.signature_size),
         :ok <- reject_padded_signature(signature),
         {:ok, decoded_signature} <- decode_unpadded_base64(signature),
         true <- matching_signature?(decoded_signature, signed_path, config) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_signature}
    end
  end

  defp reject_padded_signature(signature) do
    case String.contains?(signature, "=") do
      true -> {:error, {:invalid_signature_encoding, signature}}
      false -> :ok
    end
  end

  defp validate_encoded_signature_size(signature, signature_size) do
    max_size = max_encoded_signature_size(signature, signature_size)

    case byte_size(signature) <= max_size do
      true -> :ok
      false -> {:error, :invalid_signature}
    end
  end

  defp max_encoded_signature_size(signature, signature_size) do
    case String.contains?(signature, "=") do
      true -> padded_encoded_signature_size(signature_size)
      false -> encoded_signature_size(signature_size)
    end
  end

  defp encoded_signature_size(signature_size), do: div(signature_size * 8 + 5, 6)
  defp padded_encoded_signature_size(signature_size), do: div(signature_size + 2, 3) * 4

  defp decode_unpadded_base64(signature) do
    case Base.url_decode64(signature, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_signature_encoding, signature}}
    end
  end

  defp matching_signature?(decoded_signature, signed_path, %__MODULE__{} = config) do
    Enum.any?(config.key_salt_pairs, fn {key, salt} ->
      expected = signature_for(signed_path, key, salt, config.signature_size)

      byte_size(decoded_signature) == byte_size(expected) and
        Plug.Crypto.secure_compare(decoded_signature, expected)
    end)
  end

  defp signature_for(signed_path, key, salt, signature_size) do
    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> binary_part(0, signature_size)
  end

  @spec normalize_config!(nil | keyword()) :: t()
  # NimbleOptions rejects explicit `signature: nil`; this branch represents an absent key.
  def normalize_config!(nil), do: disabled()

  def normalize_config!(config) when is_list(config) do
    with {:ok, validated} <- NimbleOptions.validate(config, @signature_schema),
         {:ok, signature_size} <-
           validate_signature_size(Keyword.fetch!(validated, :signature_size)),
         {:ok, pairs} <-
           key_salt_pairs(
             Keyword.fetch!(validated, :keys),
             Keyword.fetch!(validated, :salts),
             Keyword.fetch!(validated, :trusted_signatures)
           ) do
      %__MODULE__{
        mode: :enabled,
        key_salt_pairs: pairs,
        signature_size: signature_size,
        trusted_signatures: MapSet.new(Keyword.fetch!(validated, :trusted_signatures))
      }
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy signature config: #{Exception.message(error)}"

      {:error, reason} ->
        raise ArgumentError, "invalid imgproxy signature config: #{reason}"
    end
  end

  def normalize_config!(_config),
    do:
      raise(ArgumentError, "invalid imgproxy signature config: signature must be a keyword list")

  defp validate_signature_size(value) when value in 1..32, do: {:ok, value}

  defp validate_signature_size(_value),
    do: {:error, "signature_size must be an integer from 1 to 32"}

  defp key_salt_pairs(keys, salts, _trusted_signatures) when length(keys) != length(salts),
    do: {:error, "keys and salts must have the same length"}

  defp key_salt_pairs([], [], []),
    do: {:error, "at least one key/salt pair or trusted signature is required"}

  defp key_salt_pairs([], [], _trusted_signatures), do: {:ok, []}

  defp key_salt_pairs(keys, salts, _trusted_signatures) do
    keys
    |> Enum.zip(salts)
    |> Enum.reduce_while({:ok, []}, fn {key, salt}, {:ok, pairs} ->
      with {:ok, key} <- decode_hex(key),
           {:ok, salt} <- decode_hex(salt) do
        {:cont, {:ok, [{key, salt} | pairs]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_hex(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, ""} -> {:error, "keys and salts must be non-empty hex-encoded strings"}
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "keys and salts must be non-empty hex-encoded strings"}
    end
  end
end

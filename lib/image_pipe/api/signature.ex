defmodule ImagePipe.API.Signature do
  @moduledoc """
  HMAC signing, verification, and expiry checks for ImagePipe URLs.

  `verify/3` runs before lexing. Its `sig_segment` and `signed_path` come
  directly from `ImagePipe.API.Path.split_signature/1`. The MAC covers
  raw bytes from the slash after the signature through the mount-relative
  path's end, excluding the query. Neither function normalizes the path:
  duplicate slashes affect the signature and may be rejected later by parsing.

  `config[:keys]` is an ordered list of hex-encoded keys. `sign/2` uses the
  first; verification tries each with `Plug.Crypto.secure_compare/2` and
  returns the matching index, exposed as `:sig_key_index` telemetry for key rotation.
  """

  @signature_size 43

  @type config :: keyword()

  @doc """
  Verifies `sig_segment` (as returned by `ImagePipe.API.Path.split_signature/1`) against
  `signed_path` under the configured ordered key list.

  Returns `{:ok, nil}` when no keys or signature are present, and
  `{:ok, key_index}` when a signature matches.
  """
  @spec verify(sig_segment :: String.t() | nil, signed_path :: String.t(), config()) ::
          {:ok, key_index :: non_neg_integer() | nil}
          | {:error, :missing_signature | :invalid_signature | :signature_without_keys}
  def verify(sig_segment, signed_path, config) do
    keys = raw_keys(config)
    do_verify(keys, sig_segment, signed_path)
  end

  defp do_verify([], nil, _signed_path), do: {:ok, nil}
  defp do_verify([], _sig_segment, _signed_path), do: {:error, :signature_without_keys}
  defp do_verify([_ | _], nil, _signed_path), do: {:error, :missing_signature}

  defp do_verify(keys, sig_segment, signed_path) do
    case decode_signature(sig_segment) do
      {:ok, decoded} ->
        case matching_key_index(decoded, signed_path, keys) do
          nil -> {:error, :invalid_signature}
          index -> {:ok, index}
        end

      :error ->
        {:error, :invalid_signature}
    end
  end

  @doc """
  Signs `path` with the first configured key — used by URL helpers and
  tests, never by the verification path.
  """
  @spec sign(path :: String.t(), config()) :: String.t()
  def sign(path, config) do
    [first_key | _rest] = raw_keys(config)

    first_key
    |> mac_for(path)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Checks expiry against the supplied Unix timestamp in seconds.

  `expires` remains valid at its own timestamp; only earlier timestamps are
  expired. The request lifecycle supplies `System.os_time(:second)` by default.
  """
  @spec expired?(expires :: pos_integer() | nil, now :: integer()) :: boolean()
  def expired?(nil, _now), do: false
  def expired?(expires, now) when is_integer(expires), do: expires < now

  # -- key material ---------------------------------------------------------

  defp raw_keys(config) do
    config
    |> Keyword.fetch!(:keys)
    |> Enum.map(&hex_decode!/1)
  end

  defp hex_decode!(hex_key) do
    {:ok, decoded} = Base.decode16(hex_key, case: :mixed)
    decoded
  end

  # -- signature decode/encode -----------------------------------------------

  defp decode_signature(sig) when byte_size(sig) == @signature_size do
    Base.url_decode64(sig, padding: false)
  end

  defp decode_signature(_sig), do: :error

  defp matching_key_index(decoded_signature, signed_path, keys) do
    keys
    |> Enum.with_index()
    |> Enum.find_value(fn {key, index} ->
      expected = mac_for(key, signed_path)

      if Plug.Crypto.secure_compare(decoded_signature, expected) do
        index
      end
    end)
  end

  defp mac_for(key, signed_path), do: :crypto.mac(:hmac, :sha256, key, signed_path)
end

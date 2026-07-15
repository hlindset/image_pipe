defmodule ImagePipe.Dialect.Native.Signature do
  @moduledoc """
  HMAC signing and verification for the native URL dialect, plus the
  `expires` gate [native §Signing, §Byte-level contract].

  `verify/3` is called before any lexing of the request path has
  happened: its two path-derived inputs (`sig_segment`, `signed_path`)
  come straight from `ImagePipe.Dialect.Native.Path.split_signature/1`,
  the raw pre-parse byte split — "verify first, parse second, with zero
  scanning" [native §Signing]. The MAC covers `signed_path` exactly as
  `split_signature/1` returns it: the raw bytes from the `/` following
  the sig segment through the end of the mount-relative path, query
  excluded. No normalization happens here or in `split_signature/1`, so
  e.g. a duplicate slash is signature-significant and verifies against
  the bytes as sent — normalization-sensitive rejection (an empty
  segment) is a parse-time concern, not a signing-time one.

  Keys are host config (`config[:keys]`), an ordered list of hex-encoded
  strings [native §Config]. The first key signs (`sign/2`); verification
  tries each key in order with `Plug.Crypto.secure_compare/2` and
  returns the matched key's index, so key rotation is observable via the
  returned index (surfaced as `:sig_key_index` telemetry metadata by
  Task 15).
  """

  @signature_size 43

  @type config :: keyword()

  @doc """
  Verifies `sig_segment` (as returned by `Path.split_signature/1`) against
  `signed_path` under the configured ordered key list.

  Returns `{:ok, nil}` when the request is legitimately unsigned (no keys
  configured, no `sig` segment present) and `{:ok, key_index}` when a
  signature matched — one success shape, so callers never need a special
  unsigned branch.
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
  The `expires` gate [native §Signing: "not identity material"]. `now` is
  an injected unix timestamp (seconds) rather than a live clock read, so
  callers stay deterministic under test; the chain (Task 15) passes
  `System.os_time(:second)`.

  `expires` is valid through and including its own timestamp — only
  strictly-past timestamps are expired.
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

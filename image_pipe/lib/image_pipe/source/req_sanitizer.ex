defmodule ImagePipe.Source.ReqSanitizer do
  @moduledoc false

  # Strips adapter-internal options and denied request headers from the Req
  # options before a source fetch, so adapter config never reaches the wire and
  # unsafe forwarded headers never leak to the origin. The adapter passes its own
  # always-denied base set (host/signing headers). Conditional headers are always
  # stripped: revalidation sends its own validators, and a host's would make an
  # origin answer a first fetch with 304. The byte headers below, and Req's
  # `range:` option, are additionally stripped when the adapter requests
  # byte-header stripping.

  @conditional_header_names [
    "if-none-match",
    "if-modified-since",
    "if-match",
    "if-unmodified-since",
    "if-range"
  ]
  @cacheable_byte_header_names ["range", "accept", "accept-encoding"]
  @byte_option_keys [:range]

  @spec sanitize_req_options(keyword(), [atom()], [String.t()], boolean()) :: keyword()
  def sanitize_req_options(
        req_options,
        internal_option_keys,
        base_denied_headers,
        strip_byte_headers?
      ) do
    denied =
      denied_header_names(base_denied_headers ++ @conditional_header_names, strip_byte_headers?)

    req_options
    |> Keyword.drop(internal_option_keys ++ byte_option_keys(strip_byte_headers?))
    |> Keyword.update(:headers, [], &reject_denied(&1, denied))
  end

  defp denied_header_names(base, true), do: base ++ @cacheable_byte_header_names
  defp denied_header_names(base, false), do: base

  defp byte_option_keys(true), do: @byte_option_keys
  defp byte_option_keys(false), do: []

  defp reject_denied(headers, denied) do
    Enum.reject(headers, fn {name, _value} -> header_name(name) in denied end)
  end

  @doc """
  The header name Req sends for `name`, lowercased. Req writes an atom name
  such as `:accept_encoding` as `accept-encoding`.
  """
  @spec header_name(atom() | String.t()) :: String.t()
  def header_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.replace("_", "-") |> String.downcase()

  def header_name(name) when is_binary(name), do: String.downcase(name)
end

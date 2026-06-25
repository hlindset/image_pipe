defmodule ImagePipe.Source.ReqSanitizer do
  @moduledoc false

  # Strips adapter-internal options and denied request headers from the Req
  # options before a source fetch, so adapter config never reaches the wire and
  # unsafe forwarded headers never leak to the origin. The adapter passes its own
  # always-denied base set (host/signing headers); the byte-range headers below
  # are additionally stripped when the adapter requests byte-header stripping.

  @cacheable_byte_header_names ["range", "accept", "accept-encoding"]

  @spec sanitize_req_options(keyword(), [atom()], [String.t()], boolean()) :: keyword()
  def sanitize_req_options(
        req_options,
        internal_option_keys,
        base_denied_headers,
        strip_byte_headers?
      ) do
    denied = denied_header_names(base_denied_headers, strip_byte_headers?)

    req_options
    |> Keyword.drop(internal_option_keys)
    |> Keyword.update(:headers, [], &reject_denied(&1, denied))
  end

  defp denied_header_names(base, true), do: base ++ @cacheable_byte_header_names
  defp denied_header_names(base, false), do: base

  defp reject_denied(headers, denied) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) in denied
    end)
  end
end

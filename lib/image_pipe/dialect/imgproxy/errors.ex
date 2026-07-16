defmodule ImagePipe.Dialect.Imgproxy.Errors do
  @moduledoc """
  Dialect-owned error -> HTTP status mapping for imgproxy's protocol
  [spec §Errors]:

    * invalid / unsupported / malformed signature -> **403**, body
      `"invalid image request: \#{inspect(reason)}"` where `reason` is the
      BARE atom (`:invalid_signature`, `:invalid_signature_encoding`,
      `:unsupported_signature`) — never the caught tuple this dialect's own
      `Signature.verify/3` returns for the latter two, matching the
      framework's own `send_signature_error/2`
      (`ImagePipe.Parser.Imgproxy.handle_error/2` inspects the bare atom
      even though it pattern-matched `{:invalid_signature_encoding, sig}` /
      `{:unsupported_signature, sig}`).
    * `expires` elapsed (`{:expired_request, n}`) -> **400**, via the generic
      parse-failure clause below — `inspect({:expired_request, n})` already
      produces the framework's exact pinned body. Upstream imgproxy
      documents 404 here; ImagePipe's 400 is a known, documented divergence
      (`docs/imgproxy_support_matrix.md`), preserved by this port —
      changing it is a conformance change out of scope for this migration.
    * every other parse/validation failure -> **400**, body
      `"invalid image request: \#{inspect(reason)}"`.
    * core stage errors (`{:source, _}`, `{:decode, _}`, `{:transform, _}`) ->
      `ImagePipe.Response.ErrorStatus`'s reusable default table (source ->
      502-class, decode -> 415, transform -> 422). `{:transform, inner}` is
      rewrapped as `{:transform_error, inner}` before reaching `ErrorStatus`
      — this dialect's own `Pipeline.run/4` tags a chain failure
      `{:transform, _}` where `ErrorStatus` expects the `_error`-suffixed
      domain tag (mirrors `ImagePipe.Dialect.Native.Errors`'s identical
      rewrap for its own `{:transform, inner}` reason).

  `ErrorStatus` is a reusable *default*, not a core-owned protocol mapping:
  the dialect adopts it for core stage errors and owns its gate mappings
  (403/400) outright — the design's "core does not own protocol status
  mapping" clause.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  alias ImagePipe.Response.ErrorStatus

  @spec send(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, :invalid_signature, _config) do
    send_signature_error(conn, :invalid_signature)
  end

  def send(%Plug.Conn{} = conn, {:invalid_signature_encoding, _signature}, _config) do
    send_signature_error(conn, :invalid_signature_encoding)
  end

  def send(%Plug.Conn{} = conn, {:unsupported_signature, _signature}, _config) do
    send_signature_error(conn, :unsupported_signature)
  end

  def send(%Plug.Conn{} = conn, {:source, _reason} = reason, config) do
    send_core_stage_error(conn, reason, config)
  end

  def send(%Plug.Conn{} = conn, {:decode, _reason} = reason, config) do
    send_core_stage_error(conn, reason, config)
  end

  def send(%Plug.Conn{} = conn, {:transform, inner}, config) do
    send_core_stage_error(conn, {:transform_error, inner}, config)
  end

  def send(%Plug.Conn{} = conn, reason, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp send_signature_error(%Plug.Conn{} = conn, reason) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "invalid image request: #{inspect(reason)}")
  end

  defp send_core_stage_error(%Plug.Conn{} = conn, reason, config) do
    {status, message} = ErrorStatus.resolve_status(reason, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end
end

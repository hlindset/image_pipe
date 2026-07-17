defmodule ImagePipe.Dialect.Imgproxy.Errors do
  @moduledoc """
  Dialect-owned error -> HTTP status mapping for imgproxy's protocol
  [spec §Errors]:

    * invalid / unsupported / malformed signature -> **403**, body
      `"invalid image request: \#{inspect(reason)}"` where `reason` is the
      BARE atom (`:invalid_signature`, `:invalid_signature_encoding`,
      `:unsupported_signature`) — never the caught tuple this dialect's own
      `Signature.verify/3` returns for the latter two.
    * `expires` elapsed (`{:expired_request, n}`) -> **400**, via the generic
      parse-failure clause below — `inspect({:expired_request, n})` produces
      the body the wire suite pins. Upstream imgproxy documents 404 here;
      ImagePipe's 400 is a known, deliberate divergence
      (`docs/imgproxy_support_matrix.md`).
    * every other parse/validation failure -> **400**, body
      `"invalid image request: \#{inspect(reason)}"`.
    * core stage errors -> `ImagePipe.Response.ErrorStatus`'s reusable
      default table. Every reason the chain can carry out of a stage is
      routed there explicitly, because this module's fallback clause is a
      400 (imgproxy's parse-failure protocol), not a status lookup —
      an unrouted stage error would silently render as a client parse
      error:
      - `{:source, _}` -> 502-class; `{:decode, _}` -> 415;
        `{:input_limit, _}` -> 413.
      - `{:unsupported_output_format, _}` -> 501 (negotiation's
        `Policy.ensure_capable/2`, pre-fetch).
      - `{:detector, :unavailable}` -> 422 (the `detector_required` gate,
        pre-fetch). Rewrapped as `{:detector_unavailable, :unavailable}` —
        the plan-validation tag `ErrorStatus` knows, and the exact one
        `ImagePipe.Plug` hands its own `Sender.send_result/3`, so every
        stack renders one status and one message for one failure.
      - `{:encode, _, _}` and `{:encode, :empty_stream}` -> 500
        (`Output.Encoder.stream_output/3`). The 2-tuple is the forced
        first-chunk pull yielding no bytes — `build_and_pump/6`'s `:empty`
        arm — and must render the 500 "error encoding image", not this
        module's parse-failure 400 fallback.
      - `{:session, _}` -> 500. The delivery session failed around the
        producer rather than inside it, which carries no image-domain
        reason; rewrapped as an `{:encode, _, _}` exactly as
        `ImagePipe.Request.Runner.normalize_delivery_error/1` does, so every
        stack renders one message for one failure.
      - `{:transform, {:materialize_error, _}}` -> 415. A materialization
        failure is a decode failure (AGENTS.md), so it is rewrapped as
        `{:decode, _}` — the taxonomy `ImagePipe.Decode.with_image/4` itself
        produces, and the one `ImagePipe.Request.Processor` reaches through
        its own `classify_materialize_error/1`. Clause order matters: this
        precedes the general `{:transform, _}` clause.
      - `{:transform, inner}` -> 422. Rewrapped as `{:transform_error,
        inner}` — this dialect's own `Pipeline.run/4` tags a chain failure
        `{:transform, _}` where `ErrorStatus` expects the `_error`-suffixed
        domain tag (mirrors `ImagePipe.Dialect.Native.Errors`'s identical
        rewrap for its own `{:transform, inner}` reason).

  `ErrorStatus` is a reusable *default*, not a core-owned protocol mapping:
  the dialect adopts it for core stage errors and owns its gate mappings
  (403/400) outright — the design's "core does not own protocol status
  mapping" clause.

  ## Negotiation headers ride the error

  `send/4`'s optional `headers` are the negotiated `Output.Policy`'s own
  (`policy.headers` — `[{"vary", "Accept"}]` for an automatic output, `[]`
  for an explicit one). An Accept-negotiated response must carry `Vary:
  Accept` even when it fails, or a shared cache may serve the failure to a
  client whose `Accept` would have negotiated a working outcome.

  Only the chain's post-negotiation call sites pass them, which is exactly
  the framework's own boundary: `Runner.process_prepared_stream/6` tags
  `policy.headers` onto `Policy.ensure_capable/2` and `Delivery.stream/5`
  failures, while `ImagePipe.Plug`'s pre-negotiation errors — parser, plan
  validation, detector, source *resolve* — carry `[]`. So a source FETCH
  failure varies and a source RESOLVE failure does not; that asymmetry is
  the framework's, mirrored deliberately.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  alias ImagePipe.Response.ErrorStatus

  @type header() :: {String.t(), String.t()}

  @spec send(Plug.Conn.t(), term(), keyword(), [header()]) :: Plug.Conn.t()
  def send(conn, reason, config, headers \\ [])

  def send(%Plug.Conn{} = conn, :invalid_signature, _config, headers) do
    send_signature_error(conn, :invalid_signature, headers)
  end

  def send(%Plug.Conn{} = conn, {:invalid_signature_encoding, _signature}, _config, headers) do
    send_signature_error(conn, :invalid_signature_encoding, headers)
  end

  def send(%Plug.Conn{} = conn, {:unsupported_signature, _signature}, _config, headers) do
    send_signature_error(conn, :unsupported_signature, headers)
  end

  def send(%Plug.Conn{} = conn, {:detector, :unavailable}, config, headers) do
    send_core_stage_error(conn, {:detector_unavailable, :unavailable}, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:source, _reason} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:decode, _reason} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:input_limit, _reason} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:unsupported_output_format, _format} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:encode, _exception, _stacktrace} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:encode, :empty_stream} = reason, config, headers) do
    send_core_stage_error(conn, reason, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:session, reason}, config, headers) do
    exception = RuntimeError.exception("delivery session failed: #{inspect(reason)}")
    send_core_stage_error(conn, {:encode, exception, []}, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config, headers) do
    send_core_stage_error(conn, {:decode, reason}, config, headers)
  end

  def send(%Plug.Conn{} = conn, {:transform, inner}, config, headers) do
    send_core_stage_error(conn, {:transform_error, inner}, config, headers)
  end

  def send(%Plug.Conn{} = conn, reason, _config, headers) do
    conn
    |> put_headers(headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp send_signature_error(%Plug.Conn{} = conn, reason, headers) do
    conn
    |> put_headers(headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "invalid image request: #{inspect(reason)}")
  end

  defp send_core_stage_error(%Plug.Conn{} = conn, reason, config, headers) do
    {status, message} = ErrorStatus.resolve_status(reason, config)

    conn
    |> put_headers(headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  defp put_headers(%Plug.Conn{} = conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end
end

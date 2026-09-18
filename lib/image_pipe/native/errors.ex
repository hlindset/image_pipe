defmodule ImagePipe.Native.Errors do
  @moduledoc """
  Dialect-owned error → HTTP status mapping for the native URL dialect.

  Parse failures render the compiler-style diagnostic body
  (`ImagePipe.Native.DiagnosticRenderer`) [native §Error
  diagnostics]. Signature failures stay terse — 403, no spans, no echoed
  path [native §Signing: "a signature oracle should not explain itself"].
  Resolved output-policy failures use a fixed safe 400 response. Everything
  else (source/decode/limit/encode/output errors) routes through
  the shared `ImagePipe.Response.ErrorStatus` status table.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  alias ImagePipe.Native.Diagnostic
  alias ImagePipe.Native.DiagnosticRenderer
  alias ImagePipe.Native.Path
  alias ImagePipe.Response.ErrorStatus

  @spec send(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, {:invalid_request, diagnostics}, _config)
      when is_list(diagnostics) do
    body = DiagnosticRenderer.render(Path.diagnostic_path(conn), diagnostics)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, body)
  end

  def send(%Plug.Conn{} = conn, reason, _config)
      when reason in [:missing_signature, :invalid_signature] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "invalid signature")
  end

  def send(%Plug.Conn{} = conn, :signature_without_keys, _config) do
    diagnostic = %Diagnostic{
      reason: :signature_without_keys,
      message: "sig is not accepted: no signing keys are configured",
      spans: [sig_span(conn)]
    }

    body = DiagnosticRenderer.render(Path.diagnostic_path(conn), [diagnostic])

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, body)
  end

  def send(%Plug.Conn{} = conn, :expired, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  def send(%Plug.Conn{} = conn, :invalid_concealed_source, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  def send(%Plug.Conn{} = conn, {:invalid_source, _reason}, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid source")
  end

  def send(%Plug.Conn{} = conn, {:invalid_output, _reason}, _config) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid output")
  end

  def send(%Plug.Conn{} = conn, {:detector, :unavailable}, config) do
    {status, message} = ErrorStatus.resolve_status({:detector_unavailable, :unavailable}, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  # ImagePipe.Native.Pipeline.run/4 wraps every
  # ImagePipe.Transform.Chain.execute/3 failure as `{:transform, inner}`
  # (`pipeline.ex`'s `run_chain/3`); `inner` is usually `{:transform_error,
  # reason}` (an operation's own validation/runtime failure) but can also be
  # `{:materialize_error, reason}` (a decode-time random-access failure, e.g.
  # during a materializing trim) — per AGENTS.md, materialization failures
  # are decode failures and must surface as `{:decode, _}` (415), the same
  # taxonomy `ImagePipe.Decode.with_image/4` itself produces.
  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}, config) do
    {status, message} = ErrorStatus.resolve_status({:decode, reason}, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  def send(%Plug.Conn{} = conn, {:transform, inner}, config) do
    {status, message} = ErrorStatus.resolve_status({:transform_error, inner}, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  def send(%Plug.Conn{} = conn, reason, config) do
    {status, message} = ErrorStatus.resolve_status(reason, config)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  defp sig_span(conn) do
    {sig, _signed_path} = Path.split_signature(conn)
    {1, byte_size("sig=" <> sig)}
  end
end

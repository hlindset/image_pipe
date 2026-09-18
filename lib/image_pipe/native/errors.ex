defmodule ImagePipe.Native.Errors do
  @moduledoc """
  Maps request errors to HTTP responses.

  Parse failures use `ImagePipe.Native.DiagnosticRenderer`. Signature failures
  return a terse 403 without spans or echoed paths to avoid a signature oracle.
  Resolved output-policy failures return a fixed safe 400. Source, decode,
  limit, encode, and output errors use `ImagePipe.Response.ErrorStatus`.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  alias ImagePipe.Native.Diagnostic
  alias ImagePipe.Native.DiagnosticRenderer
  alias ImagePipe.Native.Path
  alias ImagePipe.Response.ErrorStatus

  @spec send(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, {:invalid_request, diagnostics})
      when is_list(diagnostics) do
    body = DiagnosticRenderer.render(Path.diagnostic_path(conn), diagnostics)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, body)
  end

  def send(%Plug.Conn{} = conn, reason)
      when reason in [:missing_signature, :invalid_signature] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "invalid signature")
  end

  def send(%Plug.Conn{} = conn, :signature_without_keys) do
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

  def send(%Plug.Conn{} = conn, :expired) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  def send(%Plug.Conn{} = conn, :invalid_concealed_source) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "not found")
  end

  def send(%Plug.Conn{} = conn, {:invalid_source, _reason}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid source")
  end

  def send(%Plug.Conn{} = conn, {:invalid_output, _reason}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid output")
  end

  def send(%Plug.Conn{} = conn, {:detector, :unavailable}) do
    {status, message} = ErrorStatus.resolve_status({:detector_unavailable, :unavailable})

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  # Random-access materialization failures are decode failures (415), including
  # those returned while executing an operation such as trim.
  def send(%Plug.Conn{} = conn, {:transform, {:materialize_error, reason}}) do
    {status, message} = ErrorStatus.resolve_status({:decode, reason})

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  def send(%Plug.Conn{} = conn, {:transform, inner}) do
    {status, message} = ErrorStatus.resolve_status({:transform_error, inner})

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  def send(%Plug.Conn{} = conn, reason) do
    {status, message} = ErrorStatus.resolve_status(reason)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  defp sig_span(conn) do
    {sig, _signed_path} = Path.split_signature(conn)
    {1, byte_size("sig=" <> sig)}
  end
end

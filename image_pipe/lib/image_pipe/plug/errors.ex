defmodule ImagePipe.Plug.Errors do
  # Maps request errors to HTTP responses.
  #
  # Parse failures use `ImagePipe.Plug.DiagnosticRenderer`. Signature failures
  # return a terse 403 without spans or echoed paths to avoid a signature oracle.
  # Resolved output-policy failures return a fixed safe 400. Source, decode,
  # limit, encode, and output errors use `ImagePipe.Response.ErrorStatus`.
  @moduledoc false

  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  alias ImagePipe.API.Diagnostic
  alias ImagePipe.API.Path
  alias ImagePipe.Plug.DiagnosticRenderer
  alias ImagePipe.Plug.Request
  alias ImagePipe.Response.ErrorStatus
  alias ImagePipe.Telemetry.Summary

  @spec send(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, {:invalid_request, diagnostics})
      when is_list(diagnostics) do
    body = DiagnosticRenderer.render(diagnostic_path(conn), diagnostics)
    Summary.put(%{reason: Enum.map_join(diagnostics, "; ", & &1.message)})

    conn
    |> put_text_content_type()
    |> send_resp(400, body)
  end

  def send(%Plug.Conn{} = conn, reason)
      when reason in [:missing_signature, :invalid_signature] do
    Summary.put(%{reason: "invalid signature"})

    conn
    |> put_text_content_type()
    |> send_resp(403, "invalid signature")
  end

  def send(%Plug.Conn{} = conn, :signature_without_keys) do
    diagnostic = %Diagnostic{
      reason: :signature_without_keys,
      message: "sig is not accepted: no signing keys are configured",
      spans: [sig_span(conn)]
    }

    body = DiagnosticRenderer.render(diagnostic_path(conn), [diagnostic])
    Summary.put(%{reason: diagnostic.message})

    conn
    |> put_text_content_type()
    |> send_resp(400, body)
  end

  def send(%Plug.Conn{} = conn, :expired) do
    Summary.put(%{reason: "expired"})

    conn
    |> put_text_content_type()
    |> send_resp(410, "expired")
  end

  def send(%Plug.Conn{} = conn, :invalid_concealed_source) do
    Summary.put(%{reason: "not found"})

    conn
    |> put_text_content_type()
    |> send_resp(404, "not found")
  end

  def send(%Plug.Conn{} = conn, {:invalid_source, _reason}) do
    Summary.put(%{reason: "invalid source"})

    conn
    |> put_text_content_type()
    |> send_resp(400, "invalid source")
  end

  def send(%Plug.Conn{} = conn, {:invalid_output, _reason}) do
    Summary.put(%{reason: "invalid output"})

    conn
    |> put_text_content_type()
    |> send_resp(400, "invalid output")
  end

  def send(%Plug.Conn{} = conn, reason) do
    {status, message} = ErrorStatus.resolve_status(reason)
    Summary.put(%{reason: message})

    conn
    |> server_error_no_store(status)
    |> put_text_content_type()
    |> send_resp(status, message)
  end

  # A server error is transient, so a host lifetime meant for images must not
  # keep it in a cache. Client errors keep the host's `Cache-Control`, which
  # the runner has already capped on an expiring URL.
  defp server_error_no_store(conn, status) when status >= 500,
    do: put_resp_header(conn, "cache-control", "no-store")

  defp server_error_no_store(conn, _status), do: conn

  # A diagnostic body echoes the request path, so browsers must not sniff a
  # text body into HTML.
  defp put_text_content_type(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp diagnostic_path(conn), do: conn |> Request.mount_relative_path() |> Path.diagnostic_path()

  defp sig_span(conn) do
    {sig, _signed_path} = conn |> Request.mount_relative_path() |> Path.split_signature()
    {1, byte_size("sig=" <> sig)}
  end
end

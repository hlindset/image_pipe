defmodule ImagePipe.Dialect.Imgproxy.ErrorsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy.Errors

  defp base_conn, do: conn(:get, "/")

  defp send_error(reason, config \\ []), do: Errors.send(base_conn(), reason, config)

  describe "signature failures -> 403" do
    test "bare :invalid_signature" do
      conn = send_error(:invalid_signature)

      assert conn.status == 403
      assert conn.resp_body == "invalid image request: :invalid_signature"
      assert ["text/plain" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    end

    test "{:invalid_signature_encoding, sig} renders the bare-atom body, not the tuple" do
      conn = send_error({:invalid_signature_encoding, "abc=="})

      assert conn.status == 403
      assert conn.resp_body == "invalid image request: :invalid_signature_encoding"
    end

    test "{:unsupported_signature, sig} renders the bare-atom body, not the tuple" do
      conn = send_error({:unsupported_signature, "unsafe"})

      assert conn.status == 403
      assert conn.resp_body == "invalid image request: :unsupported_signature"
    end
  end

  describe "parse/validation failures -> 400" do
    test "an arbitrary parse-stage reason renders inspect(reason)" do
      conn = send_error({:invalid_dpr, "3.0"})

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:invalid_dpr, \"3.0\"}"
    end
  end

  describe "expired requests" do
    test "{:expired_request, n} -> 400, framework-identical body (documented divergence from upstream's 404)" do
      conn = send_error({:expired_request, 100})

      assert conn.status == 400
      assert conn.resp_body == "invalid image request: {:expired_request, 100}"
    end
  end

  describe "core stage errors delegate to ErrorStatus" do
    test "{:source, {:bad_status, 503}} -> 502" do
      conn = send_error({:source, {:bad_status, 503}})

      assert conn.status == 502
      assert conn.resp_body == "upstream responded 503"
    end

    test "{:decode, reason} -> 415" do
      conn = send_error({:decode, :corrupt})

      assert conn.status == 415
    end

    test "{:transform, reason} -> 422" do
      conn = send_error({:transform, :bad_geometry})

      assert conn.status == 422
    end

    test "{:input_limit, reason} -> 413" do
      conn = send_error({:input_limit, {5000, 5000}})

      assert conn.status == 413
      assert conn.resp_body == "source image is too large"
    end

    test "{:unsupported_output_format, format} -> 501" do
      conn = send_error({:unsupported_output_format, :avif})

      assert conn.status == 501
      assert conn.resp_body == "requested output format is not supported by this server"
    end

    test "{:encode, exception, stacktrace} -> 500" do
      conn = send_error({:encode, RuntimeError.exception("boom"), []})

      assert conn.status == 500
      assert conn.resp_body == "error encoding image"
    end

    test "{:session, reason} -> 500, rendered as an encode failure" do
      conn = send_error({:session, :timeout})

      assert conn.status == 500
      assert conn.resp_body == "error encoding image"
    end

    # A materialization failure is a decode failure (AGENTS.md), so it must not
    # ride the generic {:transform, _} clause out as a 422.
    test "{:transform, {:materialize_error, reason}} -> 415, not 422" do
      conn = send_error({:transform, {:materialize_error, :truncated}})

      assert conn.status == 415
      assert conn.resp_body == "source response is not a supported image"
    end
  end
end

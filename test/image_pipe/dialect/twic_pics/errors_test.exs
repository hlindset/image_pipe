defmodule ImagePipe.Dialect.TwicPics.ErrorsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.TwicPics.Errors

  defp base_conn, do: conn(:get, "/")

  describe "parse failures" do
    test "known and unknown reasons remain TwicPics parse 400s" do
      for reason <- [{:invalid_quality, "101"}, {:future_parse_reason, :detail}] do
        conn = Errors.send_parse(base_conn(), reason, [])

        assert conn.status == 400
        assert conn.resp_body == "invalid image request: #{inspect(reason)}"
        assert ["text/plain" <> _rest] = Plug.Conn.get_resp_header(conn, "content-type")
        assert Plug.Conn.get_resp_header(conn, "vary") == []
      end
    end
  end

  describe "core stage classification" do
    test "routes the complete stage matrix through ErrorStatus-compatible rewraps" do
      matrix = [
        {{:source, {:bad_status, 503}}, 502, "upstream responded 503"},
        {{:decode, :corrupt}, 415, "source response is not a supported image"},
        {{:input_limit, {5000, 5000}}, 413, "source image is too large"},
        {{:unsupported_output_format, :avif}, 501,
         "requested output format is not supported by this server"},
        {{:encode, RuntimeError.exception("boom"), []}, 500, "error encoding image"},
        {{:encode, :empty_stream}, 500, "error encoding image"},
        {{:session, :timeout}, 500, "error encoding image"},
        {{:transform, {:materialize_error, :truncated}}, 415,
         "source response is not a supported image"},
        {{:transform, :bad_geometry}, 422, "invalid image transform"}
      ]

      for {reason, status, body} <- matrix do
        conn = Errors.send(base_conn(), reason, [])

        assert conn.status == status, inspect(reason)
        assert conn.resp_body == body, inspect(reason)
      end
    end

    test "an unknown core failure is a 500, never a parse 400 or success" do
      conn = Errors.send(base_conn(), {:future_core_failure, :detail}, [])

      assert conn.status == 500
      assert conn.resp_body == "internal server error"
    end
  end

  describe "negotiation headers" do
    test "post-negotiation failures preserve the Policy headers" do
      headers = [{"vary", "Accept"}]

      for reason <- [
            {:source, :receive_timeout},
            {:decode, :corrupt},
            {:input_limit, :too_large},
            {:encode, :empty_stream},
            {:session, :timeout},
            {:transform, :bad_geometry},
            {:future_core_failure, :detail}
          ] do
        conn = Errors.send(base_conn(), reason, [], headers)

        assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept"], inspect(reason)
      end
    end

    test "pre-negotiation unsupported output and parse failures carry no Policy headers" do
      unsupported = Errors.send(base_conn(), {:unsupported_output_format, :avif}, [])
      parse = Errors.send_parse(base_conn(), {:invalid_quality, "101"}, [])

      assert Plug.Conn.get_resp_header(unsupported, "vary") == []
      assert Plug.Conn.get_resp_header(parse, "vary") == []
    end

    test "an explicit policy's empty header list adds no Vary" do
      conn = Errors.send(base_conn(), {:decode, :corrupt}, [], [])

      assert Plug.Conn.get_resp_header(conn, "vary") == []
    end
  end
end

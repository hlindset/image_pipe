defmodule ImagePipe.Source.ReqStreamTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Test.RawSourceOrigin

  defp open_body!(req_options, runtime_opts) do
    {:ok, response} = ReqStream.open(req_options, runtime_opts)
    response.stream
  end

  test "an incomplete Content-Length response is a truncated body" do
    {_origin, url} = raw_origin("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort")
    stream = open_body!([url: url], [])
    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :truncated_body
  end

  test "an incomplete chunked response is a truncated body" do
    {_origin, url} =
      raw_origin("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nshort\r\n")

    stream = open_body!([url: url], [])
    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :truncated_body
  end

  test "a reset after body delivery preserves the observable transport or truncation failure" do
    {origin, url} = raw_origin("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort", :reset)

    stream =
      open_body!([url: url], [])
      |> Stream.map(fn chunk ->
        send(origin, :reset)
        chunk
      end)

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    # Some platforms report a reset as :closed; framing still proves truncation.
    assert error.reason in [:connection_reset, :truncated_body]
  end

  test "invalid chunk framing remains an invalid body" do
    {_origin, url} =
      raw_origin("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\nnot-hex\r\n")

    stream = ReqStream.open([url: url], [])
    assert stream == {:error, {:source, :invalid_body}}
  end

  defp raw_origin(response, finish \\ :close) do
    origin =
      start_supervised!({RawSourceOrigin, test_pid: self(), response: response, finish: finish})

    assert_receive {:origin_ready, ^origin, url}
    {origin, url}
  end

  test "cross-origin redirects do not forward authorization or cookies" do
    plug = fn conn ->
      case conn.host do
        "first.test" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer private"]

          conn
          |> Plug.Conn.put_resp_header("location", "https://second.test/image")
          |> Plug.Conn.send_resp(302, "")

        "second.test" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == []
          assert Plug.Conn.get_req_header(conn, "cookie") == []
          Plug.Conn.send_resp(conn, 200, "bytes")
      end
    end

    stream =
      open_body!(
        [
          url: "https://first.test/image",
          plug: plug,
          auth: {:bearer, "private"},
          headers: [{"cookie", "session=private"}]
        ],
        max_redirects: 1
      )

    assert Enum.join(stream) == "bytes"
  end

  test "streams an IPv6 origin with bounded connection and pool timeouts" do
    origin =
      start_supervised!(
        {Bandit,
         plug: fn conn, _opts -> Plug.Conn.send_resp(conn, 200, "image bytes") end,
         ip: {0, 0, 0, 0, 0, 0, 0, 1},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(origin)

    stream =
      open_body!(
        [url: "http://[::1]:#{port}/image.jpg"],
        connect_timeout: 1_000,
        pool_timeout: 1_000
      )

    assert Enum.join(stream) == "image bytes"
  end

  test "runs validate_target before connecting and returns the denial reason" do
    plug = fn _conn -> flunk("must not connect when target is denied") end

    stream =
      ReqStream.open(
        [url: "https://blocked.example/x", plug: plug],
        validate_target: fn _url -> {:error, :denied_address} end
      )

    assert stream == {:error, {:source, :denied_address}}
  end

  test "follows a redirect itself and validates the hop target" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://hop.example/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:got, conn.host, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    seen = self()

    stream =
      open_body!(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn url ->
          send(seen, {:validated, url})
          :ok
        end,
        max_redirects: 1
      )

    assert Enum.join(stream) == "image bytes"
    assert_received {:validated, "https://assets.example.com/redirect.jpg"}
    assert_received {:validated, "https://hop.example/other.jpg"}
    assert_received {:got, "hop.example", "/other.jpg"}
  end

  test "denies a redirect hop before connecting to it" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://internal.example/x")
        |> Plug.Conn.send_resp(302, "")

      %{host: "internal.example"} ->
        flunk("must not connect to denied hop")

      conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
    end

    stream =
      ReqStream.open(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn
          "https://internal.example/x" -> {:error, :denied_host}
          _ -> :ok
        end,
        max_redirects: 3
      )

    assert stream == {:error, {:source, :denied_host}}
  end

  test "exhausting max_redirects fails with too_many_redirects" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/loop")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.open(
        [url: "https://assets.example.com/loop", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    assert stream == {:error, {:source, :too_many_redirects}}
  end

  test "a protocol-relative redirect Location is merged to an absolute target before validation" do
    plug = fn
      %{request_path: "/r.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "//hop.example/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:got, conn.host, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    seen = self()

    stream =
      open_body!(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn url ->
          send(seen, {:validated, url})
          :ok
        end,
        max_redirects: 1
      )

    assert Enum.join(stream) == "image bytes"
    # protocol-relative // inherits the https scheme from the base URL
    assert_received {:validated, "https://assets.example.com/r.jpg"}
    assert_received {:validated, "https://hop.example/other.jpg"}
    assert_received {:got, "hop.example", "/other.jpg"}
  end

  test "an origin non-success status surfaces as {:bad_status, status}" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end

    stream =
      ReqStream.open(
        [url: "https://assets.example.com/missing.jpg", plug: plug],
        validate_target: fn _ -> :ok end
      )

    assert stream == {:error, {:source, {:bad_status, 404}}}
  end

  test "a connection failure surfaces as :connect_error" do
    port = closed_port()

    stream =
      ReqStream.open(
        [url: "http://127.0.0.1:#{port}/x.jpg", connect_options: [timeout: 200]],
        validate_target: fn _ -> :ok end
      )

    assert stream == {:error, {:source, :connect_error}}
  end

  test "a 3xx without a Location header surfaces as :invalid_redirect" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 302, "") end

    stream =
      ReqStream.open(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    assert stream == {:error, {:source, :invalid_redirect}}
  end

  test "a 3xx with redirects disabled surfaces as :redirect_not_followed" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/other.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.open(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 0
      )

    assert stream == {:error, {:source, :redirect_not_followed}}
  end

  test "a mid-body receive timeout surfaces as :receive_timeout" do
    {url, server} = start_stalling_origin()
    server_ref = Process.monitor(server)

    stream =
      open_body!(
        [url: url],
        validate_target: fn _ -> :ok end,
        receive_timeout: 100
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :receive_timeout

    Process.exit(server, :kill)
    assert_receive {:DOWN, ^server_ref, :process, ^server, _reason}
  end

  test "a scheme-downgrade redirect is normalized and validated with the new scheme" do
    plug = fn
      %{request_path: "/r.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://assets.example.com/plain.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:got, conn.scheme, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    seen = self()

    stream =
      open_body!(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn url ->
          send(seen, {:validated, url})
          :ok
        end,
        max_redirects: 1
      )

    assert Enum.join(stream) == "image bytes"
    assert_received {:validated, "https://assets.example.com/r.jpg"}
    assert_received {:validated, "http://assets.example.com/plain.jpg"}
    assert_received {:got, :http, "/plain.jpg"}
  end

  # Binds an ephemeral port, then frees it so a connection attempt is refused.
  defp closed_port do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listen_socket)
    :gen_tcp.close(listen_socket)
    port
  end

  # A raw origin that returns a chunked 200 head and then never sends a body
  # chunk, holding the connection open until the client gives up — the mid-body
  # receive-timeout path.
  defp start_stalling_origin do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0)

        head =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: image/jpeg\r\n" <>
            "transfer-encoding: chunked\r\n\r\n"

        :ok = :gen_tcp.send(socket, head)
        # Block until the client closes, without ever sending a body chunk.
        :gen_tcp.recv(socket, 0, :infinity)
      end)

    {"http://127.0.0.1:#{port}", server}
  end
end

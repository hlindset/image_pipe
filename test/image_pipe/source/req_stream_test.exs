defmodule ImagePipe.Source.ReqStreamTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.StreamError

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
      ReqStream.stream(
        [url: "http://[::1]:#{port}/image.jpg"],
        connect_timeout: 1_000,
        pool_timeout: 1_000
      )

    assert Enum.join(stream) == "image bytes"
  end

  test "runs validate_target before connecting and raises the denial reason" do
    plug = fn _conn -> flunk("must not connect when target is denied") end

    stream =
      ReqStream.stream(
        [url: "https://blocked.example/x", plug: plug],
        validate_target: fn _url -> {:error, :denied_address} end
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_address
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
      ReqStream.stream(
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
      ReqStream.stream(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn
          "https://internal.example/x" -> {:error, :denied_host}
          _ -> :ok
        end,
        max_redirects: 3
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_host
  end

  test "exhausting max_redirects fails with too_many_redirects" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/loop")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/loop", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :too_many_redirects
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
      ReqStream.stream(
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
      ReqStream.stream(
        [url: "https://assets.example.com/missing.jpg", plug: plug],
        validate_target: fn _ -> :ok end
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == {:bad_status, 404}
  end

  test "a connection failure surfaces as :connect_error" do
    port = closed_port()

    stream =
      ReqStream.stream(
        [url: "http://127.0.0.1:#{port}/x.jpg", connect_options: [timeout: 200]],
        validate_target: fn _ -> :ok end
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :connect_error
  end

  test "a 3xx without a Location header surfaces as :invalid_redirect" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 302, "") end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :invalid_redirect
  end

  test "a 3xx with redirects disabled surfaces as :redirect_not_followed" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/other.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/r.jpg", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 0
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :redirect_not_followed
  end

  test "a mid-body receive timeout surfaces as :receive_timeout" do
    {url, server} = start_stalling_origin()
    server_ref = Process.monitor(server)

    stream =
      ReqStream.stream(
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
      ReqStream.stream(
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

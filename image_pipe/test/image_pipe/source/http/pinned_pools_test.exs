defmodule ImagePipe.Source.HTTP.PinnedPoolsTest do
  # Sweeps act on every pinned pool in the VM, so no other fetches may run.
  use ExUnit.Case, async: false

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.HTTP.PinnedPools

  @loopback {127, 0, 0, 1}
  @loopback6 {0, 0, 0, 0, 0, 0, 0, 1}
  @tls Path.expand("../../../support/image_pipe/test/tls", __DIR__)
  @idle 60_000
  @interval 30_000

  test "stops a pool that stays idle and fetches again on a new connection" do
    origin = start_origin()

    assert fetch_body(origin.port) == "image bytes"
    assert_receive {:connection, first}

    now = System.monotonic_time(:millisecond)
    PinnedPools.sweep(now + @idle + 1)
    refute_received {:closed, ^first}
    PinnedPools.sweep(now + @idle + @interval + 2)
    assert_receive {:closed, ^first}

    assert fetch_body(origin.port) == "image bytes"
    assert_receive {:connection, second}
    assert second != first
  end

  test "a retired pool takes no new fetches and stops after its last one" do
    origin = start_origin()
    {:ok, response} = fetch(origin.port, "/slow")
    assert_receive {:connection, slow}

    now = System.monotonic_time(:millisecond)
    PinnedPools.sweep(now + @idle + 1)

    # A fetch after retirement opens a new pool instead of joining the old one.
    assert fetch_body(origin.port) == "image bytes"
    assert_receive {:connection, fresh}
    assert fresh != slow

    PinnedPools.sweep(now + @idle + @interval + 2)
    assert_receive {:waiting, server}
    send(server, :finish)
    assert Enum.join(response.stream) == "slow bytes"

    PinnedPools.sweep(now + @idle + 2 * @interval + 3)
    assert_receive {:closed, ^slow}
  end

  test "keeps an HTTP/2 pool until the fetch streaming on it finishes" do
    test_pid = self()

    port =
      tls_origin(fn conn, _ ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "slow ")
        send(test_pid, {:waiting, self()})

        receive do
          :finish -> :ok
        end

        {:ok, conn} = Plug.Conn.chunk(conn, "bytes")
        conn
      end)

    {:ok, response} = fetch(port, "/slow", [@loopback], :https)
    assert_receive {:waiting, server}

    now = System.monotonic_time(:millisecond)
    PinnedPools.sweep(now + @idle + 1)
    PinnedPools.sweep(now + @idle + @interval + 2)

    send(server, :finish)
    assert Enum.join(response.stream) == "slow bytes"
  end

  test "prefers a resolved address that already has a pool" do
    v4 = start_origin(ip: @loopback, body: "IPv4")
    start_origin(ip: @loopback6, port: v4.port, body: "IPv6")

    assert fetch_body(v4.port, "/image", [@loopback, @loopback6]) == "IPv4"
    assert fetch_body(v4.port, "/image", [@loopback6, @loopback]) == "IPv4"
  end

  test "doesn't prefer an address that failed to connect" do
    v4 = start_origin(ip: @loopback)
    {:ok, listener} = :gen_tcp.listen(v4.port, [:inet6, :binary, ip: @loopback6, active: false])
    test_pid = self()

    start_supervised!(
      {Task, fn -> refuse(listener, test_pid) end},
      id: make_ref()
    )

    assert fetch_body(v4.port, "/image", [@loopback6, @loopback]) == "image bytes"
    assert_receive :refused
    assert fetch_body(v4.port, "/image", [@loopback6, @loopback]) == "image bytes"
    refute_received :refused
  end

  # Accepts each connection and closes it before any response.
  defp refuse(listener, test_pid) do
    {:ok, socket} = :gen_tcp.accept(listener)
    send(test_pid, :refused)
    :gen_tcp.close(socket)
    refuse(listener, test_pid)
  end

  defp fetch_body(port, path \\ "/image", addresses \\ [@loopback]) do
    {:ok, response} = fetch(port, path, addresses)
    Enum.join(response.stream)
  end

  defp fetch(port, path, addresses \\ [@loopback], scheme \\ :http) do
    {:ok, config} =
      HTTP.validate_options(
        allowed_hosts: ["origin.test"],
        address_policy: [allow_loopback: true],
        address_resolver: fn _host -> {:ok, addresses} end,
        req_options: req_options(scheme)
      )

    url = %URL{scheme: scheme, host: "origin.test", port: port, path: [String.trim(path, "/")]}
    {:ok, source} = HTTP.resolve(url, config, [])
    HTTP.fetch(source, config, [])
  end

  defp req_options(:http), do: []

  defp req_options(:https) do
    [
      connect_options: [
        protocols: [:http2],
        transport_opts: [cacertfile: Path.join(@tls, "ca.pem")]
      ]
    ]
  end

  defp tls_origin(plug) do
    pid =
      start_supervised!(
        {Bandit,
         plug: plug,
         scheme: :https,
         ip: @loopback,
         port: 0,
         certfile: Path.join(@tls, "origin.pem"),
         keyfile: Path.join(@tls, "origin-key.pem")},
        id: make_ref()
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # A keep-alive origin that reports each connection by its client port, and
  # when the client closes it. `/slow` sends half its body, then the rest on
  # `:finish`.
  defp start_origin(opts \\ []) do
    ip = Keyword.get(opts, :ip, @loopback)
    family = if tuple_size(ip) == 8, do: [:inet6], else: []

    {:ok, listener} =
      :gen_tcp.listen(
        Keyword.get(opts, :port, 0),
        family ++ [:binary, ip: ip, active: false, reuseaddr: true]
      )

    {:ok, {_address, port}} = :inet.sockname(listener)
    test_pid = self()
    body = Keyword.get(opts, :body, "image bytes")

    start_supervised!(
      {Task, fn -> accept(listener, test_pid, body) end},
      id: make_ref()
    )

    %{port: port}
  end

  defp accept(listener, test_pid, body) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, {_address, peer}} = :inet.peername(socket)
    send(test_pid, {:connection, peer})

    {:ok, pid} =
      Task.start_link(fn ->
        receive do
          :go -> serve(socket, test_pid, peer, body)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :go)
    accept(listener, test_pid, body)
  end

  defp serve(socket, test_pid, peer, body) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, "GET /slow" <> _} ->
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nslow ")
        send(test_pid, {:waiting, self()})

        receive do
          :finish -> :ok = :gen_tcp.send(socket, "bytes")
        end

        serve(socket, test_pid, peer, body)

      {:ok, _request} ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
          )

        serve(socket, test_pid, peer, body)

      {:error, :closed} ->
        send(test_pid, {:closed, peer})
    end
  end
end

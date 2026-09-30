defmodule ImagePipe.Source.HTTP.PinningTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Response

  @tls Path.expand("../../../support/image_pipe/test/tls", __DIR__)
  @loopback {127, 0, 0, 1}
  @loopback6 {0, 0, 0, 0, 0, 0, 0, 1}

  test "connects to the resolved IP while verifying TLS and preserving the HTTP host" do
    test_pid = self()

    port =
      origin(fn conn, _ ->
        send(test_pid, {:request, conn.host, Plug.Conn.get_req_header(conn, "host")})
        Plug.Conn.send_resp(conn, 200, "image bytes")
      end)

    assert {:ok, response} = fetch("origin.test", port)
    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:request, "origin.test", [host]}
    assert host == "origin.test:#{port}"
    Response.close(response)
  end

  test "rejects a certificate for a different hostname at the validated IP" do
    port = origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "wrong host") end)
    assert {:error, {:source, :connect_error}} = fetch("wrong.test", port)
  end

  for {protocol, wire_protocol} <- [http1: :"HTTP/1.1", http2: :"HTTP/2"] do
    @protocol protocol
    @wire_protocol wire_protocol

    test "isolates hostnames sharing an IP in #{protocol} pools and preserves SNI" do
      test_pid = self()

      port =
        origin(
          fn conn, _ ->
            send(test_pid, {:request, conn.host, Plug.Conn.get_http_protocol(conn)})
            Plug.Conn.send_resp(conn, 200, conn.host)
          end,
          thousand_island_options: [
            transport_options: [
              sni_fun: fn hostname ->
                send(test_pid, {:sni, to_string(hostname)})
                []
              end
            ]
          ]
        )

      for host <- ["origin.test", "other.test"] do
        assert {:ok, response} =
                 fetch(host, port,
                   req_options: tls_options(protocols: Enum.uniq([@protocol, :http1]))
                 )

        assert Enum.join(response.stream) == host
        assert_receive {:sni, ^host}
        expected = @wire_protocol
        assert_receive {:request, ^host, ^expected}
      end
    end

    test "uses the newly validated address instead of a pooled #{protocol} connection" do
      port = origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "IPv4") end)
      origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "IPv6") end, ip: @loopback6, port: port)

      for {ip, expected} <- [{@loopback, "IPv4"}, {@loopback6, "IPv6"}] do
        assert {:ok, response} =
                 fetch("origin.test", port,
                   address_resolver: fn _ -> {:ok, [ip]} end,
                   req_options: tls_options(protocols: Enum.uniq([@protocol, :http1]))
                 )

        assert Enum.join(response.stream) == expected
      end
    end
  end

  test "falls back only within the validated address set when a connection fails" do
    port = origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "IPv6") end, ip: @loopback6)

    assert {:ok, response} =
             fetch("origin.test", port,
               address_resolver: fn _ -> {:ok, [@loopback, @loopback6]} end
             )

    assert Enum.join(response.stream) == "IPv6"
  end

  test "denies the whole resolution if any returned address is forbidden" do
    assert {:error, {:source, :denied_address}} =
             fetch("origin.test", 443,
               address_policy: [],
               address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}, @loopback]} end
             )
  end

  test "validates and pins every redirect while stripping cross-origin credentials" do
    test_pid = self()

    port =
      origin(fn conn, _ ->
        send(
          test_pid,
          {:headers, conn.host, Plug.Conn.get_req_header(conn, "authorization"),
           Plug.Conn.get_req_header(conn, "cookie")}
        )

        case conn.host do
          "origin.test" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://other.test:#{conn.port}/final")
            |> Plug.Conn.send_resp(302, "")

          "other.test" ->
            Plug.Conn.send_resp(conn, 200, "redirected bytes")
        end
      end)

    resolver = fn host ->
      send(test_pid, {:resolved, host})
      {:ok, [@loopback]}
    end

    assert {:ok, response} =
             fetch("origin.test", port,
               allowed_hosts: ["origin.test", "other.test"],
               address_resolver: resolver,
               max_redirects: 1,
               req_options:
                 tls_options() ++ [auth: {:bearer, "test-token"}, headers: [{"cookie", "test=1"}]]
             )

    assert Enum.join(response.stream) == "redirected bytes"
    assert_receive {:resolved, "origin.test"}
    assert_receive {:resolved, "other.test"}
    assert_receive {:headers, "origin.test", ["Bearer test-token"], ["test=1"]}
    assert_receive {:headers, "other.test", [], []}
  end

  test "relative redirects retain logical resource identity and Host Vary on revalidation" do
    test_pid = self()

    port =
      origin(fn conn, _ ->
        validators = Plug.Conn.get_req_header(conn, "if-none-match")
        send(test_pid, {:request, conn.request_path, validators})

        case {conn.request_path, validators} do
          {"/image", []} ->
            conn
            |> Plug.Conn.put_resp_header("location", "/final")
            |> Plug.Conn.send_resp(302, "")

          {"/final", []} ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("v1"))
            |> Plug.Conn.put_resp_header("vary", "host")
            |> Plug.Conn.send_resp(200, "original bytes")

          {"/final", [~s("v1")]} ->
            Plug.Conn.send_resp(conn, 304, "")
        end
      end)

    assert {:ok, response} = fetch("origin.test", port, max_redirects: 1)
    assert Enum.join(response.stream) == "original bytes"
    assert_receive {:request, "/image", []}
    assert_receive {:request, "/final", []}

    assert {:not_modified, refreshed} =
             fetch("origin.test", port, [max_redirects: 1], source_validation: response.origin)

    assert refreshed.resource == response.origin.resource
    assert_receive {:request, "/image", []}
    assert_receive {:request, "/final", [~s("v1")]}
  end

  test "pins HTTP IP literals in non-canonical notation" do
    port = origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, conn.host) end, scheme: :http)
    assert {:ok, response} = fetch("2130706433", port, [], [], :http)
    assert Enum.join(response.stream) == "2130706433"
  end

  test "an HTTP proxy receives the validated address and the logical Host header" do
    test_pid = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: @loopback])
         {:ok, {_, port}} = :inet.sockname(listener)
         send(test_pid, {:proxy_port, port})

         try do
           {:ok, socket} = :gen_tcp.accept(listener)

           try do
             {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
             send(test_pid, {:proxy_request, request})
             :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nbytes")
           after
             :gen_tcp.close(socket)
           end
         after
           :gen_tcp.close(listener)
         end
       end}
    )

    assert_receive {:proxy_port, proxy_port}

    assert {:ok, response} =
             fetch(
               "origin.test",
               80,
               [
                 address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
                 req_options: [
                   connect_options: [proxy: {:http, "127.0.0.1", proxy_port, [mode: :passive]}]
                 ]
               ],
               [],
               :http
             )

    assert Enum.join(response.stream) == "bytes"
    assert_receive {:proxy_request, request}
    assert request =~ "GET http://93.184.216.34/image HTTP/1.1\r\n"
    assert request =~ "\r\nhost: origin.test\r\n"
  end

  test "a denied redirect cannot reuse an already open connection" do
    test_pid = self()
    dns = start_supervised!({Agent, fn -> [@loopback, {10, 0, 0, 1}] end})

    port =
      origin(fn conn, _ ->
        send(test_pid, :origin_request)
        conn |> Plug.Conn.put_resp_header("location", "/final") |> Plug.Conn.send_resp(302, "")
      end)

    resolver = fn _ ->
      ip = Agent.get_and_update(dns, fn [ip | rest] -> {ip, rest} end)
      {:ok, [ip]}
    end

    assert {:error, {:source, :denied_address}} =
             fetch("origin.test", port, address_resolver: resolver, max_redirects: 1)

    assert_receive :origin_request
    refute_received :origin_request
    assert Agent.get(dns, & &1) == []
  end

  test "an HTTP error does not retry another validated address" do
    port = origin(fn conn, _ -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

    origin(fn conn, _ -> Plug.Conn.send_resp(conn, 200, "wrong retry") end,
      ip: @loopback6,
      port: port
    )

    assert {:error, {:source, {:bad_status, 503}}} =
             fetch("origin.test", port,
               address_resolver: fn _ -> {:ok, [@loopback, @loopback6]} end
             )
  end

  test "signs the logical hostname and non-default port before pinning" do
    test_pid = self()

    signing = [
      access_key_id: "test-access",
      secret_access_key: "test-secret",
      service: :s3,
      region: "us-east-1",
      datetime: ~U[2026-09-21 00:00:00Z]
    ]

    port =
      origin(fn conn, _ ->
        send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.send_resp(conn, 200, "signed bytes")
      end)

    expected =
      Req.new(
        url: "https://origin.test:#{port}/image",
        aws_sigv4: signing,
        headers: [{"host", "origin.test:#{port}"}]
      )
      |> Req.prepare()

    assert {:ok, response} =
             fetch("origin.test", port, req_options: tls_options() ++ [aws_sigv4: signing])

    assert Enum.join(response.stream) == "signed bytes"
    assert_receive {:authorization, authorization}
    assert authorization == Req.Request.get_header(expected, "authorization")
  end

  test "real Plug requests process a pinned HTTPS source and reject a denied address" do
    test_pid = self()
    bytes = Image.new!(12, 8, color: :red) |> Image.write!(:memory, suffix: ".png")

    port =
      origin(fn conn, _ ->
        send(test_pid, :fetched)
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, bytes)
      end)

    source_options = [
      allowed_hosts: ["origin.test"],
      address_resolver: fn _ -> {:ok, [@loopback]} end,
      req_options: tls_options()
    ]

    config =
      ImagePipe.Plug.init(
        sources: [url: {HTTP, source_options ++ [address_policy: [allow_loopback: true]]}]
      )

    path = "/w=6/format=png/src/https://origin.test:#{port}/image"

    response = Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(config)
    assert response.status == 200
    assert Plug.Conn.get_resp_header(response, "content-type") == ["image/png"]
    assert {6, 4, 3} == response.resp_body |> Image.from_binary!() |> Image.shape()
    assert_receive :fetched

    denied = ImagePipe.Plug.init(sources: [url: {HTTP, source_options}])
    assert (Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(denied)).status == 422
    refute_received :fetched
  end

  defp origin(plug, opts \\ []) do
    pid =
      start_supervised!(
        {Bandit,
         Keyword.merge(
           [
             plug: plug,
             scheme: :https,
             ip: @loopback,
             port: 0,
             certfile: Path.join(@tls, "origin.pem"),
             keyfile: Path.join(@tls, "origin-key.pem")
           ],
           opts
         )},
        id: make_ref()
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp fetch(host, port, opts \\ [], runtime \\ [], scheme \\ :https) do
    {:ok, config} =
      HTTP.validate_options(
        Keyword.merge(
          [
            allowed_hosts: [host],
            address_policy: [allow_loopback: true],
            address_resolver: fn _host -> {:ok, [@loopback]} end,
            req_options: tls_options()
          ],
          opts
        )
      )

    {:ok, source} =
      HTTP.resolve(%URL{scheme: scheme, host: host, port: port, path: ["image"]}, config, [])

    HTTP.fetch(source, config, runtime)
  end

  defp tls_options(connect_opts \\ []) do
    [
      connect_options:
        Keyword.merge([transport_opts: [cacertfile: Path.join(@tls, "ca.pem")]], connect_opts)
    ]
  end
end

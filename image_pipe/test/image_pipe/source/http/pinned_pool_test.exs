defmodule ImagePipe.Source.HTTP.PinnedPoolTest do
  # Counts children of VM-wide supervisors, so no other test may fetch meanwhile.
  use ExUnit.Case, async: false

  alias ImagePipe.Source
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.URL

  defmodule Origin do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "body")
  end

  # Holds the connection of a request for /held, after the headers and a first
  # chunk, until the test sends :release.
  defmodule HoldingOrigin do
    def init(test), do: test

    def call(%{request_path: "/held"} = conn, test) do
      conn = Plug.Conn.send_chunked(conn, 200)
      {:ok, conn} = Plug.Conn.chunk(conn, "held")
      send(test, {:holding, self()})

      receive do
        :release -> conn
      end
    end

    def call(conn, _test), do: Plug.Conn.send_resp(conn, 200, "body")
  end

  test "pinned fetches start their connection pool once, under ImagePipe's supervisor" do
    bandit = start_supervised!({Bandit, plug: Origin, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    # A connect timeout no other test uses gives these fetches their own pool.
    req_options = [url: "http://localhost:#{port}/image", connect_options: [timeout: 4_321]]
    runtime = [validate_target: fn _url -> {:ok, [{127, 0, 0, 1}]} end]

    fetch = fn ->
      {:ok, response} = ReqStream.open(req_options, runtime)
      assert Enum.join(response.stream) == "body"
    end

    pools = fn -> length(DynamicSupervisor.which_children(ImagePipe.Source.HTTP.Pools)) end
    req_pools = fn -> length(DynamicSupervisor.which_children(Req.FinchSupervisor)) end
    {before, req_before} = {pools.(), req_pools.()}

    fetch.()
    assert pools.() == before + 1

    fetch.()
    assert pools.() == before + 1
    assert req_pools.() == req_before
  end

  # The pool's name is registered before its supervisor starts its children, so
  # a fetch that finds the name mid-start must still wait for the pool.
  test "concurrent first fetches all succeed while their connection pool starts" do
    bandit = start_supervised!({Bandit, plug: Origin, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    runtime = [validate_target: fn _url -> {:ok, [{127, 0, 0, 1}]} end]

    for timeout <- 5_100..5_119 do
      # Each round's connect timeout gives it a pool no fetch has started yet.
      req_options = [url: "http://localhost:#{port}/image", connect_options: [timeout: timeout]]

      results =
        1..32
        |> Task.async_stream(
          fn _ ->
            {:ok, response} = ReqStream.open(req_options, runtime)
            Enum.join(response.stream)
          end,
          max_concurrency: 32,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, body} -> body end)

      assert results == List.duplicate("body", 32)
    end
  end

  test "pool_size caps the connections an HTTP source opens to one origin address" do
    bandit =
      start_supervised!(
        {Bandit, plug: {HoldingOrigin, self()}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    config =
      Source.validate_config!(
        sources: [
          http: [
            adapter: HTTP,
            match: [scheme: "http"],
            options: [
              allowed_hosts: ["127.0.0.1:#{port}"],
              address_policy: [allow_loopback: true],
              pool_size: 2,
              pool_timeout: 200
            ]
          ]
        ]
      )

    fetch = fn path ->
      source = %URL{scheme: :http, host: "127.0.0.1", port: port, path: [path], query: nil}
      {:ok, resolved} = Source.resolve(source, config, [])
      Source.fetch(resolved, config, max_body_bytes: 64)
    end

    held = for _ <- 1..2, do: fetch.("held")

    holders =
      for _ <- 1..2 do
        assert_receive {:holding, pid}
        pid
      end

    assert {:error, {:source, :pool_timeout}} = fetch.("image")

    Enum.each(holders, &send(&1, :release))
    Enum.each(held, fn {:ok, response} -> assert Enum.join(response.stream) == "held" end)

    assert {:ok, response} = fetch.("image")
    assert Enum.join(response.stream) == "body"
  end

  # S3 fetches connect without pinning, through a pool Req starts.
  test "pool_size caps the connections of an unpinned fetch" do
    bandit =
      start_supervised!(
        {Bandit, plug: {HoldingOrigin, self()}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    runtime = [pool_size: 1, pool_timeout: 200]
    open = fn path -> ReqStream.open([url: "http://localhost:#{port}/#{path}"], runtime) end

    {:ok, held} = open.("held")
    assert_receive {:holding, holder}

    assert {:error, {:source, :pool_timeout}} = open.("image")

    send(holder, :release)
    assert Enum.join(held.stream) == "held"

    assert {:ok, response} = open.("image")
    assert Enum.join(response.stream) == "body"
  end
end

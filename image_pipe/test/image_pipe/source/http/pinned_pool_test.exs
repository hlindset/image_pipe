defmodule ImagePipe.Source.HTTP.PinnedPoolTest do
  # Counts children of VM-wide supervisors, so no other test may fetch meanwhile.
  use ExUnit.Case, async: false

  alias ImagePipe.Source.ReqStream

  defmodule Origin do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "body")
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
end

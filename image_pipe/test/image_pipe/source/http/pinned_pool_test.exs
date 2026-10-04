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
end

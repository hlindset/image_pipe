defmodule ImagePipe.Source.HTTP.DnsCacheOptionTest do
  # The default resolver shares one cache across the VM, so this module runs
  # alone to see only its own lookups.
  use ExUnit.Case, async: false

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.HTTP.DnsCache
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.URL

  setup do
    :ets.delete(DnsCache, "localhost")

    pid =
      start_supervised!(
        {Bandit,
         plug: fn conn, _ -> Plug.Conn.send_resp(conn, 200, "image bytes") end,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{port: port}
  end

  test "keeps the default resolver's answer", %{port: port} do
    fetch(port, [])
    assert [{"localhost", _addresses, _expires_at}] = :ets.lookup(DnsCache, "localhost")
  end

  test "dns_cache: false resolves without keeping the answer", %{port: port} do
    fetch(port, dns_cache: false)
    assert :ets.lookup(DnsCache, "localhost") == []
  end

  test "checks a cached answer against each source's address policy", %{port: port} do
    fetch(port, [])

    assert fetch_result(port, address_policy: []) == {:error, {:source, :denied_address}}
  end

  @tag :ipv6
  test "replaces a cached answer whose addresses don't connect", %{port: port} do
    # The origin listens on 127.0.0.1 only, so a stale answer of ::1 is refused.
    :ets.insert(DnsCache, {"localhost", [{0, 0, 0, 0, 0, 0, 0, 1}], :infinity})

    fetch(port, [])
    assert [{"localhost", addresses, _expires_at}] = :ets.lookup(DnsCache, "localhost")
    assert {127, 0, 0, 1} in addresses
  end

  test "keeps the cached answer when the origin doesn't answer in time", %{port: port} do
    fetch(port, [])
    [entry] = :ets.lookup(DnsCache, "localhost")

    # Connections queue in the backlog, so the request waits for an answer.
    {:ok, silent} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, backlog: 16)
    {:ok, silent_port} = :inet.port(silent)

    # The fetch also tries ::1, where nothing listens, so either failure ends it.
    assert {:error, {:source, reason}} = fetch_result(silent_port, receive_timeout: 200)
    assert reason in [:receive_timeout, :connect_error]

    assert :ets.lookup(DnsCache, "localhost") == [entry]
  end

  defp fetch(port, opts) do
    assert {:ok, response} = fetch_result(port, opts)
    assert Enum.join(response.stream) == "image bytes"
    Response.close(response)
  end

  defp fetch_result(port, opts) do
    {:ok, config} =
      HTTP.validate_options(
        Keyword.merge(
          [allowed_hosts: ["localhost:#{port}"], address_policy: [allow_loopback: true]],
          opts
        )
      )

    {:ok, source} =
      HTTP.resolve(
        %URL{scheme: :http, host: "localhost", port: port, path: ["image"]},
        config,
        []
      )

    HTTP.fetch(source, config, [])
  end
end

defmodule ImagePipe.Source.HTTP.DnsCacheOptionTest do
  # The default resolver shares one cache across the VM, so this module runs
  # alone to see only its own lookups.
  use ExUnit.Case, async: false

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.HTTP.DnsCache
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.URL

  setup do
    DnsCache.invalidate("localhost")

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

  defp fetch(port, opts) do
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

    assert {:ok, response} = HTTP.fetch(source, config, [])
    assert Enum.join(response.stream) == "image bytes"
    Response.close(response)
  end
end

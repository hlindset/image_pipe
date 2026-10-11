defmodule ImagePipe.Source.HTTP.TargetGuardTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.{AddressPolicy, TargetGuard}

  defp default_policy, do: AddressPolicy.compile([])

  defp hosts(entries) do
    {:ok, allowed} = TargetGuard.allowed_hosts(entries)
    allowed
  end

  defp resolver(map) do
    fn host -> Map.get(map, host, {:error, :nxdomain}) end
  end

  test "allows a public host that resolves to a public IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})

    assert TargetGuard.validate(
             "https://assets.example.com/x.jpg",
             hosts(["assets.example.com"]),
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}
  end

  test "denies non-http(s) scheme before host checks" do
    assert TargetGuard.validate(
             "file:///etc/passwd",
             hosts(["assets.example.com"]),
             default_policy(),
             resolver(%{})
           ) ==
             {:error, :denied_scheme}
  end

  test "denies a host outside allowed_hosts, case-insensitively matched" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})

    assert TargetGuard.validate(
             "https://ASSETS.EXAMPLE.COM/x",
             hosts(["assets.example.com"]),
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}

    assert TargetGuard.validate(
             "https://evil.example/x",
             hosts(["assets.example.com"]),
             default_policy(),
             res
           ) ==
             {:error, :denied_host}
  end

  test "denies when the host resolves to a private IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 1}]}})

    assert TargetGuard.validate(
             "https://assets.example.com/x",
             hosts(["assets.example.com"]),
             default_policy(),
             res
           ) ==
             {:error, :denied_address}
  end

  test "classifies IP-literal hosts directly without calling the resolver" do
    res = fn _ -> flunk("resolver should not be called for a literal") end

    assert TargetGuard.validate("https://10.0.0.1/x", hosts(["10.0.0.1"]), default_policy(), res) ==
             {:error, :denied_address}

    assert TargetGuard.validate(
             "https://93.184.216.34/x",
             hosts(["93.184.216.34"]),
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}
  end

  test "classifies bracketed IPv6 literal hosts" do
    res = fn _ -> flunk("resolver should not be called for a literal") end

    assert TargetGuard.validate("http://[::1]/x", hosts(["::1"]), default_policy(), res) ==
             {:error, :denied_address}
  end

  test "fails closed on resolver error, empty, and raise" do
    assert TargetGuard.validate(
             "https://h/x",
             hosts(["h"]),
             default_policy(),
             resolver(%{"h" => {:error, :nxdomain}})
           ) ==
             {:error, :denied_address}

    assert TargetGuard.validate(
             "https://h/x",
             hosts(["h"]),
             default_policy(),
             resolver(%{"h" => {:ok, []}})
           ) ==
             {:error, :denied_address}

    raise_res = fn _ -> raise "dns boom" end

    assert TargetGuard.validate("https://h/x", hosts(["h"]), default_policy(), raise_res) ==
             {:error, :denied_address}
  end

  test "denies malformed addresses returned by a host resolver" do
    for ip <- [{256, 0, 0, 1}, {-1, 0, 0, 1}, {:bad, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 65_536}] do
      assert {:error, :denied_address} =
               TargetGuard.validate(
                 "https://h/x",
                 hosts(["h"]),
                 default_policy(),
                 fn _ -> {:ok, [ip]} end
               )
    end
  end

  describe "default_resolver/1" do
    test "returns IPv4 addresses ahead of IPv6 addresses" do
      assert {:ok, [_ | _] = addresses} = TargetGuard.default_resolver("localhost")

      {v4, v6} = Enum.split_with(addresses, &(tuple_size(&1) == 4))
      assert addresses == v4 ++ v6
    end

    test "reports a host that resolves to nothing" do
      assert TargetGuard.default_resolver("no-such-host.invalid") == {:error, :nxdomain}
    end
  end

  describe "ports" do
    setup do
      %{res: resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})}
    end

    test "a bare entry allows only the scheme's default port", %{res: res} do
      allowed = hosts(["assets.example.com"])

      for url <- ["https://assets.example.com/x", "http://assets.example.com:80/x"] do
        assert {:ok, _} = TargetGuard.validate(url, allowed, default_policy(), res)
      end

      for url <- [
            "https://assets.example.com:8443/x",
            "http://assets.example.com:443/x",
            "http://assets.example.com:22/x"
          ] do
        assert TargetGuard.validate(url, allowed, default_policy(), res) == {:error, :denied_host}
      end
    end

    test "a host:port entry allows that port", %{res: res} do
      allowed = hosts(["Assets.Example.com:8443"])

      assert {:ok, _} =
               TargetGuard.validate(
                 "https://assets.example.com:8443/x",
                 allowed,
                 default_policy(),
                 res
               )

      assert TargetGuard.validate("https://assets.example.com/x", allowed, default_policy(), res) ==
               {:error, :denied_host}
    end

    test "IPv6 literals take an optional bracketed port" do
      res = fn _ -> flunk("resolver should not be called for a literal") end
      policy = AddressPolicy.compile(allow_loopback: true)

      assert {:ok, _} = TargetGuard.validate("http://[::1]/x", hosts(["[::1]"]), policy, res)

      assert {:ok, _} =
               TargetGuard.validate("http://[::1]:8080/x", hosts(["[::1]:8080"]), policy, res)

      assert TargetGuard.validate("http://[::1]:8080/x", hosts(["::1"]), policy, res) ==
               {:error, :denied_host}
    end

    test "rejects malformed entries" do
      for entry <- [
            "",
            "host:",
            "host:0",
            "host:65536",
            "host:http",
            "[::1",
            "[::1]x",
            ":80",
            "https://h:443"
          ] do
        assert TargetGuard.allowed_hosts([entry]) == {:error, entry}
      end
    end
  end
end

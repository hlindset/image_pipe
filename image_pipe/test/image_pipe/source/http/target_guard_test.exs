defmodule ImagePipe.Source.HTTP.TargetGuardTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.{AddressPolicy, TargetGuard}

  defp default_policy, do: AddressPolicy.compile([])

  defp resolver(map) do
    fn host -> Map.get(map, host, {:error, :nxdomain}) end
  end

  test "allows a public host that resolves to a public IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})

    assert TargetGuard.validate(
             "https://assets.example.com/x.jpg",
             ["assets.example.com"],
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}
  end

  test "denies non-http(s) scheme before host checks" do
    assert TargetGuard.validate(
             "file:///etc/passwd",
             ["assets.example.com"],
             default_policy(),
             resolver(%{})
           ) ==
             {:error, :denied_scheme}
  end

  test "denies a host outside allowed_hosts, case-insensitively matched" do
    res = resolver(%{"assets.example.com" => {:ok, [{93, 184, 216, 34}]}})

    assert TargetGuard.validate(
             "https://ASSETS.EXAMPLE.COM/x",
             ["assets.example.com"],
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}

    assert TargetGuard.validate(
             "https://evil.example/x",
             ["assets.example.com"],
             default_policy(),
             res
           ) ==
             {:error, :denied_host}
  end

  test "denies when the host resolves to a private IP" do
    res = resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 1}]}})

    assert TargetGuard.validate(
             "https://assets.example.com/x",
             ["assets.example.com"],
             default_policy(),
             res
           ) ==
             {:error, :denied_address}
  end

  test "classifies IP-literal hosts directly without calling the resolver" do
    res = fn _ -> flunk("resolver should not be called for a literal") end

    assert TargetGuard.validate("https://10.0.0.1/x", ["10.0.0.1"], default_policy(), res) ==
             {:error, :denied_address}

    assert TargetGuard.validate(
             "https://93.184.216.34/x",
             ["93.184.216.34"],
             default_policy(),
             res
           ) == {:ok, [{93, 184, 216, 34}]}
  end

  test "classifies bracketed IPv6 literal hosts" do
    res = fn _ -> flunk("resolver should not be called for a literal") end

    assert TargetGuard.validate("http://[::1]/x", ["::1"], default_policy(), res) ==
             {:error, :denied_address}
  end

  test "fails closed on resolver error, empty, and raise" do
    assert TargetGuard.validate(
             "https://h/x",
             ["h"],
             default_policy(),
             resolver(%{"h" => {:error, :nxdomain}})
           ) ==
             {:error, :denied_address}

    assert TargetGuard.validate(
             "https://h/x",
             ["h"],
             default_policy(),
             resolver(%{"h" => {:ok, []}})
           ) ==
             {:error, :denied_address}

    raise_res = fn _ -> raise "dns boom" end

    assert TargetGuard.validate("https://h/x", ["h"], default_policy(), raise_res) ==
             {:error, :denied_address}
  end

  test "denies malformed addresses returned by a host resolver" do
    for ip <- [{256, 0, 0, 1}, {-1, 0, 0, 1}, {:bad, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 65_536}] do
      assert {:error, :denied_address} =
               TargetGuard.validate(
                 "https://h/x",
                 ["h"],
                 default_policy(),
                 fn _ -> {:ok, [ip]} end
               )
    end
  end
end

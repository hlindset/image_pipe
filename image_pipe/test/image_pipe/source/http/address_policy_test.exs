defmodule ImagePipe.Source.HTTP.AddressPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Source.HTTP.AddressPolicy

  describe "classify/1 IPv4" do
    test "categorizes well-known IPv4 ranges" do
      assert AddressPolicy.classify({127, 0, 0, 1}) == :loopback
      assert AddressPolicy.classify({127, 5, 5, 5}) == :loopback
      assert AddressPolicy.classify({0, 0, 0, 0}) == :unspecified
      assert AddressPolicy.classify({0, 1, 2, 3}) == :unspecified
      assert AddressPolicy.classify({169, 254, 169, 254}) == :link_local
      assert AddressPolicy.classify({10, 0, 0, 1}) == :private
      assert AddressPolicy.classify({172, 16, 0, 1}) == :private
      assert AddressPolicy.classify({172, 31, 255, 255}) == :private
      assert AddressPolicy.classify({172, 32, 0, 1}) == :public
      assert AddressPolicy.classify({192, 168, 1, 1}) == :private
      assert AddressPolicy.classify({100, 64, 0, 1}) == :cgnat
      assert AddressPolicy.classify({224, 0, 0, 1}) == :multicast
      assert AddressPolicy.classify({255, 255, 255, 255}) == :broadcast
      assert AddressPolicy.classify({198, 18, 0, 1}) == :reserved
      assert AddressPolicy.classify({192, 0, 2, 5}) == :reserved
      assert AddressPolicy.classify({93, 184, 216, 34}) == :public
      assert AddressPolicy.classify({8, 8, 8, 8}) == :public
    end
  end

  describe "classify/1 IPv6 and canonicalization" do
    test "categorizes native IPv6 ranges" do
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0, 0, 0}) == :unspecified
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0, 0, 1}) == :loopback
      assert AddressPolicy.classify({0xFE80, 0, 0, 0, 0, 0, 0, 1}) == :link_local
      assert AddressPolicy.classify({0xFC00, 0, 0, 0, 0, 0, 0, 1}) == :unique_local
      assert AddressPolicy.classify({0xFD00, 0, 0, 0, 0, 0, 0, 1}) == :unique_local
      assert AddressPolicy.classify({0xFF00, 0, 0, 0, 0, 0, 0, 1}) == :multicast
      assert AddressPolicy.classify({0x2606, 0x2800, 0, 0, 0, 0, 0, 1}) == :public
    end

    test "unwraps IPv4-mapped IPv6 and classifies by embedded v4 (dotted and hex spellings)" do
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == :private
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}) == :loopback
      assert AddressPolicy.classify({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822}) == :public
    end

    test "blocks NAT64 and unwraps 6to4 by embedded v4" do
      assert AddressPolicy.classify({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}) == :reserved
      assert AddressPolicy.classify({0x2002, 0x7F00, 0x0001, 0, 0, 0, 0, 0}) == :loopback
      assert AddressPolicy.classify({0x2002, 0x5DB8, 0xD822, 0, 0, 0, 0, 0}) == :public
    end

    test "blocks the IPv6 documentation range 2001:db8::/32" do
      assert AddressPolicy.classify({0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}) == :reserved
    end

    test "unknown IPv6 never defaults to :public (deny-default)" do
      refute AddressPolicy.classify({0x3FFF, 0, 0, 0, 0, 0, 0, 1}) == :public
    end
  end

  describe "CIDR" do
    test "parse_cidr/1 accepts valid v4/v6 CIDRs and rejects junk" do
      assert {:ok, _} = AddressPolicy.parse_cidr("10.0.5.0/24")
      assert {:ok, _} = AddressPolicy.parse_cidr("2001:db8::/32")
      assert :error = AddressPolicy.parse_cidr("10.0.5.0")
      assert :error = AddressPolicy.parse_cidr("10.0.5.0/33")
      assert :error = AddressPolicy.parse_cidr("nonsense")
      assert :error = AddressPolicy.parse_cidr("2001:db8::/129")
    end

    test "in_cidr?/2 matches membership" do
      {:ok, cidr} = AddressPolicy.parse_cidr("10.0.5.0/24")
      assert AddressPolicy.in_cidr?({10, 0, 5, 7}, cidr)
      assert AddressPolicy.in_cidr?({10, 0, 5, 0}, cidr)
      assert AddressPolicy.in_cidr?({10, 0, 5, 255}, cidr)
      refute AddressPolicy.in_cidr?({10, 0, 6, 1}, cidr)
      refute AddressPolicy.in_cidr?({10, 0, 5, 7, 0, 0, 0, 0}, cidr)

      {:ok, cidr6} = AddressPolicy.parse_cidr("2001:db8::/32")
      assert AddressPolicy.in_cidr?({0x2001, 0x0DB8, 1, 2, 3, 4, 5, 6}, cidr6)
      refute AddressPolicy.in_cidr?({0x2001, 0x0DB9, 0, 0, 0, 0, 0, 0}, cidr6)
    end
  end

  describe "compile/1 + allow?/2" do
    test "default keyword policy denies all non-public, allows public" do
      pred = AddressPolicy.compile([])
      assert AddressPolicy.allow?(pred, [{93, 184, 216, 34}])
      refute AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
      refute AddressPolicy.allow?(pred, [{127, 0, 0, 1}])
    end

    test "category toggles open whole categories" do
      pred = AddressPolicy.compile(allow_private: true)
      assert AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
      refute AddressPolicy.allow?(pred, [{127, 0, 0, 1}])
    end

    test "CIDR allow opens exactly the named range" do
      pred = AddressPolicy.compile(allow: ["10.0.5.0/24"])
      assert AddressPolicy.allow?(pred, [{10, 0, 5, 7}])
      refute AddressPolicy.allow?(pred, [{10, 0, 6, 7}])
    end

    test "block-if-any: one bad address denies the whole set" do
      pred = AddressPolicy.compile([])
      refute AddressPolicy.allow?(pred, [{93, 184, 216, 34}, {10, 0, 0, 1}])
    end

    test "malformed / empty address set denies" do
      pred = AddressPolicy.compile([])
      refute AddressPolicy.allow?(pred, [])
      refute AddressPolicy.allow?(pred, [:not_an_ip])
    end

    test "function form replaces built-in decision" do
      pred = AddressPolicy.compile(fn _ip, category -> category == :public end)
      assert AddressPolicy.allow?(pred, [{93, 184, 216, 34}])
      refute AddressPolicy.allow?(pred, [{10, 0, 0, 1}])
    end

    test "function form fails closed on non-boolean return and on raise" do
      pred_bad = AddressPolicy.compile(fn _ip, _cat -> :yes end)
      refute AddressPolicy.allow?(pred_bad, [{93, 184, 216, 34}])

      pred_raise = AddressPolicy.compile(fn _ip, _cat -> raise "boom" end)
      refute AddressPolicy.allow?(pred_raise, [{93, 184, 216, 34}])
    end
  end

  describe "property: classify is total and deny-default" do
    property "no IPv4 tuple crashes classify/1" do
      check all a <- integer(0..255),
                b <- integer(0..255),
                c <- integer(0..255),
                d <- integer(0..255) do
        assert AddressPolicy.classify({a, b, c, d}) in [
                 :loopback,
                 :unspecified,
                 :link_local,
                 :private,
                 :unique_local,
                 :multicast,
                 :broadcast,
                 :cgnat,
                 :reserved,
                 :public
               ]
      end
    end

    property "default policy never allows a non-public IPv4" do
      pred = AddressPolicy.compile([])

      check all a <- integer(0..255),
                b <- integer(0..255),
                c <- integer(0..255),
                d <- integer(0..255) do
        ip = {a, b, c, d}

        if AddressPolicy.classify(ip) != :public do
          refute AddressPolicy.allow?(pred, [ip])
        end
      end
    end

    property "IPv6 classify is total over all 8-group tuples" do
      check all groups <- list_of(integer(0..0xFFFF), length: 8) do
        assert AddressPolicy.classify(List.to_tuple(groups)) in [
                 :loopback,
                 :unspecified,
                 :link_local,
                 :private,
                 :unique_local,
                 :multicast,
                 :broadcast,
                 :cgnat,
                 :reserved,
                 :public
               ]
      end
    end

    property "IPv6 outside the 2000::/3 public window denies (deny-default)" do
      # Leading group strictly above the public window (0x2000..0x3FFF) and below
      # the ULA/link-local/multicast prefixes (which start at 0xFC00) — this is the
      # unassigned/reserved space that must NEVER classify as :public.
      check all first <- integer(0x4000..0xEFFF),
                rest <- list_of(integer(0..0xFFFF), length: 7) do
        assert AddressPolicy.classify(List.to_tuple([first | rest])) == :reserved
      end
    end
  end
end

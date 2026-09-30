defmodule ImagePipe.Source.HTTP.AddressPolicy do
  @moduledoc false
  import Bitwise

  @type category ::
          :loopback
          | :unspecified
          | :link_local
          | :private
          | :unique_local
          | :multicast
          | :broadcast
          | :cgnat
          | :reserved
          | :public

  @type cidr :: {non_neg_integer(), 0..128, 32 | 128}

  @spec parse_cidr(String.t()) :: {:ok, cidr()} | :error
  def parse_cidr(string) when is_binary(string) do
    with [addr, prefix] <- String.split(string, "/", parts: 2),
         {:ok, tuple} <- :inet.parse_address(String.to_charlist(addr)),
         {prefix_int, ""} <- Integer.parse(prefix),
         bits when bits in [32, 128] <- tuple_bits(tuple),
         true <- prefix_int >= 0 and prefix_int <= bits do
      {:ok, {tuple_to_int(tuple), prefix_int, bits}}
    else
      _ -> :error
    end
  end

  def parse_cidr(_value), do: :error

  @spec in_cidr?(:inet.ip_address(), cidr()) :: boolean()
  def in_cidr?(ip, {net_int, prefix, bits}) do
    if tuple_bits(ip) == bits do
      shift = bits - prefix
      Bitwise.bsr(tuple_to_int(ip), shift) == Bitwise.bsr(net_int, shift)
    else
      false
    end
  end

  @spec classify(:inet.ip_address()) :: category()
  def classify({a, b, c, d}), do: classify_v4(a, b, c, d)

  def classify({_, _, _, _, _, _, _, _} = v6) do
    case canonicalize_v6(v6) do
      {:v4, {a, b, c, d}} -> classify_v4(a, b, c, d)
      {:v6, v6} -> classify_v6(v6)
    end
  end

  # IPv4-mapped ::ffff:0:0/96
  defp canonicalize_v6({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: {:v4, embed_v4(g, h)}
  # 6to4 2002::/16 embeds v4 in the next two groups
  defp canonicalize_v6({0x2002, g, h, _, _, _, _, _}), do: {:v4, embed_v4(g, h)}
  defp canonicalize_v6(v6), do: {:v6, v6}

  defp embed_v4(g, h) do
    <<a, b>> = <<g::16>>
    <<c, d>> = <<h::16>>
    {a, b, c, d}
  end

  defp classify_v6({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  defp classify_v6({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  # NAT64 64:ff9b::/96 — treat as non-public (we did not embed-unwrap it)
  defp classify_v6({0x64, 0xFF9B, 0, 0, 0, 0, _, _}), do: :reserved
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: :link_local
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: :unique_local
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: :multicast

  # 3fff::/20 reserved for documentation (RFC 9637) — MUST come BEFORE the 2000..3FFF public clause
  defp classify_v6({0x3FFF, b, _, _, _, _, _, _}) when b < 0x1000, do: :reserved
  # 2001:db8::/32 documentation (RFC 3849)
  defp classify_v6({0x2001, 0x0DB8, _, _, _, _, _, _}), do: :reserved
  # Global unicast 2000::/3 is the only public v6 space; everything else denies.
  defp classify_v6({a, _, _, _, _, _, _, _}) when a >= 0x2000 and a <= 0x3FFF, do: :public
  defp classify_v6(_), do: :reserved

  defp classify_v4(0, _, _, _), do: :unspecified
  defp classify_v4(127, _, _, _), do: :loopback
  defp classify_v4(169, 254, _, _), do: :link_local
  defp classify_v4(10, _, _, _), do: :private
  defp classify_v4(172, b, _, _) when b in 16..31, do: :private
  defp classify_v4(192, 168, _, _), do: :private
  defp classify_v4(100, b, _, _) when b in 64..127, do: :cgnat
  defp classify_v4(a, _, _, _) when a in 224..239, do: :multicast
  defp classify_v4(255, 255, 255, 255), do: :broadcast
  # benchmarking 198.18.0.0/15
  defp classify_v4(198, b, _, _) when b in 18..19, do: :reserved
  # documentation 192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24
  defp classify_v4(192, 0, 2, _), do: :reserved
  defp classify_v4(198, 51, 100, _), do: :reserved
  defp classify_v4(203, 0, 113, _), do: :reserved
  # 240.0.0.0/4 reserved (future use)
  defp classify_v4(a, _, _, _) when a in 240..255, do: :reserved
  defp classify_v4(_, _, _, _), do: :public

  @type predicate :: (:inet.ip_address(), category() -> boolean())

  @category_toggles %{
    allow_loopback: :loopback,
    allow_unspecified: :unspecified,
    allow_link_local: :link_local,
    allow_private: :private,
    allow_unique_local: :unique_local,
    allow_multicast: :multicast,
    allow_broadcast: :broadcast,
    allow_cgnat: :cgnat,
    allow_reserved: :reserved
  }

  @spec compile(keyword() | predicate()) :: predicate()
  def compile(fun) when is_function(fun, 2) do
    fn ip, category -> safe_bool(fun, ip, category) end
  end

  def compile(opts) when is_list(opts) do
    allowed_categories =
      for {toggle, category} <- @category_toggles,
          Keyword.get(opts, toggle, false),
          into: MapSet.new() do
        category
      end

    cidrs =
      opts
      |> Keyword.get(:allow, [])
      |> Enum.map(fn cidr ->
        {:ok, parsed} = parse_cidr(cidr)
        parsed
      end)

    fn ip, category ->
      category == :public or
        MapSet.member?(allowed_categories, category) or
        Enum.any?(cidrs, &in_cidr?(ip, &1))
    end
  end

  @spec allow?(predicate(), [:inet.ip_address()]) :: boolean()
  def allow?(_predicate, []), do: false

  def allow?(predicate, addresses) when is_list(addresses) do
    Enum.all?(addresses, fn
      {_, _, _, _} = ip -> predicate.(ip, classify(ip))
      {_, _, _, _, _, _, _, _} = ip -> predicate.(ip, classify(ip))
      _other -> false
    end)
  end

  defp safe_bool(fun, ip, category) do
    case fun.(ip, category) do
      true -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp tuple_bits({_, _, _, _}), do: 32
  defp tuple_bits({_, _, _, _, _, _, _, _}), do: 128

  defp tuple_to_int({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp tuple_to_int({a, b, c, d, e, f, g, h}) do
    [a, b, c, d, e, f, g, h]
    |> Enum.reduce(0, fn group, acc -> (acc <<< 16) + group end)
  end
end

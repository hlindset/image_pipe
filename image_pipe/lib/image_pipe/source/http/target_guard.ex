defmodule ImagePipe.Source.HTTP.TargetGuard do
  @moduledoc false

  alias ImagePipe.Source.HTTP.AddressPolicy

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  # A `nil` port stands for the default port of the request's scheme.
  @type allowed_host :: {String.t(), :inet.port_number() | nil}

  @default_ports %{"http" => 80, "https" => 443}

  @doc """
  Parses `allowed_hosts` entries: `host`, `host:port`, `[ipv6]`, or
  `[ipv6]:port`. A bare IPv6 literal is accepted without brackets when it
  names no port. Returns the first malformed entry on failure.
  """
  @spec allowed_hosts([String.t()]) :: {:ok, [allowed_host()]} | {:error, String.t()}
  def allowed_hosts(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case parse_entry(String.downcase(entry)) do
        {:ok, allowed} -> {:cont, {:ok, [allowed | acc]}}
        :error -> {:halt, {:error, entry}}
      end
    end)
    |> case do
      {:ok, allowed} -> {:ok, Enum.reverse(allowed)}
      error -> error
    end
  end

  defp parse_entry("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, ""] when host != "" -> {:ok, {host, nil}}
      [host, ":" <> port] when host != "" -> with_port(host, port)
      _other -> :error
    end
  end

  defp parse_entry(entry) do
    case String.split(entry, ":") do
      [""] -> :error
      [host] -> {:ok, {host, nil}}
      ["", _port] -> :error
      [host, port] -> with_port(host, port)
      _ipv6 -> ipv6(entry)
    end
  end

  defp ipv6(entry) do
    case :inet.parse_ipv6strict_address(String.to_charlist(entry)) do
      {:ok, _address} -> {:ok, {entry, nil}}
      {:error, _reason} -> :error
    end
  end

  defp with_port(host, port) do
    case Integer.parse(port) do
      {port, ""} when port in 1..65_535 -> {:ok, {host, port}}
      _other -> :error
    end
  end

  @doc "Whether `host` (lowercased) and `port` are allowed for `scheme`."
  @spec allowed?([allowed_host()], String.t(), String.t(), :inet.port_number()) :: boolean()
  def allowed?(allowed_hosts, scheme, host, port) do
    Enum.any?(allowed_hosts, fn
      {^host, nil} -> port == Map.fetch!(@default_ports, scheme)
      {^host, ^port} -> true
      _other -> false
    end)
  end

  @spec validate(String.t(), [allowed_host()], AddressPolicy.predicate(), resolver()) ::
          {:ok, [:inet.ip_address()]} | {:error, :denied_scheme | :denied_host | :denied_address}
  def validate(url, allowed_hosts, predicate, resolver) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         host = String.downcase(uri.host || ""),
         :ok <- check_host(allowed_hosts, uri.scheme, host, uri.port),
         {:ok, addresses} <- resolve(host, resolver) do
      case Enum.all?(addresses, &:inet.is_ip_address/1) and
             AddressPolicy.allow?(predicate, addresses) do
        true -> {:ok, Enum.uniq(addresses)}
        false -> {:error, :denied_address}
      end
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_uri), do: {:error, :denied_scheme}

  defp check_host(allowed_hosts, scheme, host, port) do
    if host != "" and allowed?(allowed_hosts, scheme, host, port),
      do: :ok,
      else: {:error, :denied_host}
  end

  defp resolve(host, resolver) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, [ip]}
      {:error, _} -> resolve_via(host, resolver)
    end
  end

  defp resolve_via(host, resolver) do
    case resolver.(host) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      _ -> {:error, :denied_address}
    end
  rescue
    _ -> {:error, :denied_address}
  end

  @spec default_resolver(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def default_resolver(host) do
    charlist = String.to_charlist(host)

    # The lookups are independent network round trips, so run them together.
    # :inet.getaddrs/2 applies its own timeout.
    v6_task = Task.async(fn -> getaddrs(charlist, :inet6) end)
    v4 = getaddrs(charlist, :inet)

    case v4 ++ Task.await(v6_task, :infinity) do
      [] -> {:error, :nxdomain}
      addresses -> {:ok, addresses}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _} -> []
    end
  end
end

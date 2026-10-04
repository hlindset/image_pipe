defmodule ImagePipe.Source.HTTP.TargetGuard do
  @moduledoc false

  alias ImagePipe.Source.HTTP.AddressPolicy

  @type resolver :: (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})

  @spec validate(String.t(), [String.t()], AddressPolicy.predicate(), resolver()) ::
          {:ok, [:inet.ip_address()]} | {:error, :denied_scheme | :denied_host | :denied_address}
  def validate(url, allowed_hosts, predicate, resolver) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- check_scheme(uri),
         host = String.downcase(uri.host || ""),
         :ok <- check_host(host, allowed_hosts),
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

  defp check_host(host, allowed_hosts) do
    if host != "" and host in allowed_hosts, do: :ok, else: {:error, :denied_host}
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
    # The two lookups are independent round trips, so they run side by side.
    v6 = Task.async(fn -> getaddrs(charlist, :inet6) end)
    v4 = getaddrs(charlist, :inet)

    case v4 ++ Task.await(v6, :infinity) do
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

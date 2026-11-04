defmodule ImagePipe.Source.HTTP.PinnedTarget do
  @moduledoc false

  alias ImagePipe.Source.HTTP.PinnedPools
  alias ImagePipe.Source.HTTP.Pool

  @minimum_attempt_ms 100

  # Pin at the transport boundary, after signing and other request steps. Logical
  # URLs stay intact for redirects, origin validators and request authentication.
  #
  # A fetch moves to the next address only while the deadline (a monotonic
  # time in milliseconds, or `:infinity`) leaves time for it. Each address
  # waits for a pooled connection and for the response no longer than the
  # time left.
  @spec attach(Req.Request.t(), [:inet.ip_address()] | nil, integer() | :infinity) ::
          Req.Request.t()
  def attach(request, nil, _deadline), do: request

  def attach(%Req.Request{adapter: Req.Finch} = request, addresses, deadline) do
    addresses = live_first(addresses, request.url)

    request
    |> Req.Request.put_header("host", authority(request.url))
    |> Req.Request.append_request_steps(
      image_pipe_pin: fn req, acc, fun, state, next ->
        connect(req, addresses, deadline, acc, fun, state, next)
      end
    )
  end

  def attach(request, _addresses, _deadline), do: request

  defp connect(req, [ip | rest], deadline, acc, fun, state, next) do
    callback = fn event, response, acc, state ->
      response = put_in(response.request.url, req.url)
      fun.(event, response, acc, state)
    end

    {pinned, key} = req |> within_deadline(deadline) |> pin(ip)

    case next.(pinned, acc, callback, state) do
      {{:error, %Req.TransportError{}}, %Req.Response{status: nil}, _, _} = result ->
        PinnedPools.connected(key, false)

        # An attempt with less than this left would likely time out, and its
        # error would replace the one that used up the time.
        if rest == [] or remaining(deadline) < @minimum_attempt_ms,
          do: result,
          else: connect(req, rest, deadline, acc, fun, state, next)

      result ->
        PinnedPools.connected(key, true)
        result
    end
  end

  defp within_deadline(req, :infinity), do: req

  defp within_deadline(req, deadline) do
    left = remaining(deadline)

    req
    |> Req.Request.put_option(:receive_timeout, min(req.options.receive_timeout, left))
    |> Req.Request.put_option(
      :finch,
      Keyword.update!(req.options.finch, :pool_timeout, &min(&1, left))
    )
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp pin(req, ip) do
    hostname = req.url.host
    address = address(ip)
    finch = Map.fetch!(req.options, :finch)

    conn_opts =
      finch
      |> Keyword.fetch!(:conn_opts)
      |> Keyword.update!(:transport_opts, &address_family(&1, ip))
      |> connection_identity(req.url)

    url = %{req.url | host: address}

    [{:name, name} | request_options] =
      finch |> Keyword.put(:conn_opts, conn_opts) |> Pool.named()

    key = {scheme(url), address, url.port, hostname, name}
    tag = PinnedPools.tag(hostname, PinnedPools.generation(key))

    {Req.merge(%{req | url: url}, finch: [name: name, pool_tag: tag] ++ request_options), key}
  end

  # Mint retries a failed IPv6 connection over IPv4 unless `inet4` is false.
  # A pinned IPv6 address can't be reached over IPv4, and the retry would
  # replace the connection error with a failed lookup of the address.
  defp address_family(transport_opts, ip) when tuple_size(ip) == 8,
    do: Keyword.merge(transport_opts, inet6: true, inet4: false)

  defp address_family(transport_opts, _ip), do: Keyword.put(transport_opts, :inet6, false)

  # An address whose live pool last connected may still hold an open
  # connection, so it goes first. The order is otherwise the resolver's.
  defp live_first(addresses, url) do
    {live, other} =
      Enum.split_with(addresses, fn ip ->
        PinnedPools.live?(scheme(url), address(ip), url.port, url.host)
      end)

    live ++ other
  end

  defp scheme(%URI{scheme: "https"}), do: :https
  defp scheme(%URI{scheme: "http"}), do: :http

  defp address(ip), do: ip |> :inet.ntoa() |> to_string()

  defp connection_identity(opts, %URI{scheme: "https", host: hostname}) do
    opts
    |> Keyword.put(:hostname, hostname)
    |> Keyword.update!(
      :transport_opts,
      &Keyword.put(&1, :server_name_indication, String.to_charlist(hostname))
    )
  end

  # Mint uses :hostname in a plain HTTP proxy's absolute request target. Let it
  # use the pinned IP; the explicit Host header still carries the origin name.
  defp connection_identity(opts, %URI{scheme: "http"}), do: Keyword.delete(opts, :hostname)

  defp authority(uri) do
    %{uri | userinfo: nil, path: nil, query: nil, fragment: nil}
    |> URI.to_string()
    |> String.replace_prefix("#{uri.scheme}://", "")
  end
end

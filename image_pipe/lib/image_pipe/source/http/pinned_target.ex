defmodule ImagePipe.Source.HTTP.PinnedTarget do
  @moduledoc false

  alias ImagePipe.Source.HTTP.PinnedPools

  # Pin at the transport boundary, after signing and other request steps. Logical
  # URLs stay intact for redirects, origin validators and request authentication.
  @spec attach(Req.Request.t(), [:inet.ip_address()] | nil) :: Req.Request.t()
  def attach(request, nil), do: request

  def attach(%Req.Request{adapter: Req.Finch} = request, addresses) do
    addresses = live_first(addresses, request.url)

    request
    |> Req.Request.put_header("host", authority(request.url))
    |> Req.Request.append_request_steps(
      image_pipe_pin: fn req, acc, fun, state, next ->
        connect(req, addresses, acc, fun, state, next)
      end
    )
  end

  def attach(request, _addresses), do: request

  defp connect(req, [ip | rest], acc, fun, state, next) do
    callback = fn event, response, acc, state ->
      response = put_in(response.request.url, req.url)
      fun.(event, response, acc, state)
    end

    {pinned, key} = pin(req, ip)

    case next.(pinned, acc, callback, state) do
      {{:error, %Req.TransportError{}}, %Req.Response{status: nil}, _, _} = result ->
        PinnedPools.connected(key, false)
        if rest == [], do: result, else: connect(req, rest, acc, fun, state, next)

      result ->
        PinnedPools.connected(key, true)
        result
    end
  end

  defp pin(req, ip) do
    hostname = req.url.host
    address = address(ip)
    finch = Map.fetch!(req.options, :finch)

    conn_opts =
      finch
      |> Keyword.fetch!(:conn_opts)
      |> Keyword.update!(:transport_opts, &Keyword.put(&1, :inet6, tuple_size(ip) == 8))
      |> connection_identity(req.url)

    url = %{req.url | host: address}

    [{:name, name} | request_options] =
      finch |> Keyword.put(:conn_opts, conn_opts) |> named_pool()

    key = {name, scheme(url), address, url.port, hostname}
    tag = PinnedPools.tag(hostname, PinnedPools.generation(key))

    {Req.merge(%{req | url: url}, finch: [name: name, pool_tag: tag] ++ request_options), key}
  end

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

  # Given pool options, Req starts or finds their Finch instance through its
  # one DynamicSupervisor on every request. A pool started here once, under
  # ImagePipe's supervisor, is passed to Req by name instead. Req accepts only
  # its build and request options alongside a name.
  @pools ImagePipe.Source.HTTP.Pools
  @request_options [
    :pool_tag,
    :unix_socket,
    :pool_timeout,
    :receive_timeout,
    :request_timeout,
    :pool_strategy
  ]

  defp named_pool(finch) do
    {request_options, pool_options} = Keyword.split(finch, @request_options)
    name = pool_name(pool_options)

    if Process.whereis(name) == nil do
      case DynamicSupervisor.start_child(
             @pools,
             {Finch, name: name, pools: %{default: [start_pool_metrics?: true] ++ pool_options}}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    [name: name] ++ request_options
  end

  defp pool_name(pool_options) do
    hash =
      pool_options |> :erlang.term_to_binary() |> :erlang.md5() |> Base.encode32(padding: false)

    Module.concat(@pools, hash)
  end

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

defmodule ImagePipe.Source.HTTP.PinnedTarget do
  @moduledoc false

  # Pin at the transport boundary, after signing and other request steps. Logical
  # URLs stay intact for redirects, origin validators and request authentication.
  @spec attach(Req.Request.t(), [:inet.ip_address()] | nil) :: Req.Request.t()
  def attach(request, nil), do: request

  def attach(%Req.Request{adapter: Req.Finch} = request, addresses) do
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

    case next.(pin(req, ip), acc, callback, state) do
      {{:error, %Req.TransportError{}}, %Req.Response{status: nil}, _, _}
      when rest != [] ->
        connect(req, rest, acc, fun, state, next)

      result ->
        result
    end
  end

  defp pin(req, ip) do
    hostname = req.url.host
    address = ip |> :inet.ntoa() |> to_string()
    finch = Map.fetch!(req.options, :finch)

    conn_opts =
      finch
      |> Keyword.fetch!(:conn_opts)
      |> Keyword.update!(:transport_opts, &Keyword.put(&1, :inet6, tuple_size(ip) == 8))
      |> connection_identity(req.url)

    finch =
      finch
      |> Keyword.put(:conn_opts, conn_opts)
      |> Keyword.put(:pool_tag, {:image_pipe, hostname})

    Req.merge(%{req | url: %{req.url | host: address}}, finch: finch)
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

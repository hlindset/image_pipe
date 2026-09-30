defmodule ImagePipe.Source.ReqStream do
  @moduledoc false

  alias ImagePipe.Source.HTTP.PinnedTarget
  alias ImagePipe.Source.Origin
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry.Trace.ReqStep

  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000

  @spec open(keyword(), keyword()) ::
          {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, ImagePipe.Source.error()}
  def open(req_options, runtime_opts) do
    case open_response(req_options, runtime_opts) do
      %{response: response, origin: origin} = state ->
        {:ok,
         %Response{
           stream: body_stream(state),
           origin: origin,
           close: fn -> cancel_response(response) end
         }}

      {:not_modified, origin} ->
        {:not_modified, origin}

      {:error, {:source, _}} = error ->
        error

      {:error, reason} ->
        {:error, {:source, reason}}
    end
  end

  defp body_stream(state) do
    Stream.resource(
      fn -> state end,
      fn
        {:done, state} -> {:halt, state}
        state -> stream_response(state)
      end,
      fn
        {:done, state} -> cancel_response(state.response)
        state -> cancel_response(state.response)
      end
    )
  end

  defp open_response(req_options, runtime_opts) do
    validate = Keyword.get(runtime_opts, :validate_target, fn _url -> :ok end)
    max_redirects = option(req_options, runtime_opts, :max_redirects, 0)
    redirects_allowed? = max_redirects > 0
    follow(req_options, runtime_opts, validate, max_redirects, redirects_allowed?)
  end

  defp follow(req_options, runtime_opts, validate, redirects_left, redirects_allowed?) do
    url = Keyword.fetch!(req_options, :url)

    case validate.(url) do
      :ok ->
        request_and_route(req_options, runtime_opts, validate, redirects_left, redirects_allowed?)

      {:ok, addresses} ->
        request_and_route(
          req_options,
          runtime_opts,
          validate,
          redirects_left,
          redirects_allowed?,
          addresses
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_and_route(
         req_options,
         runtime_opts,
         validate,
         redirects_left,
         redirects_allowed?,
         addresses \\ nil
       ) do
    clock = Keyword.get(runtime_opts, :clock, fn -> System.system_time(:second) end)
    previous = Keyword.get(runtime_opts, :source_validation)

    request =
      req_options
      |> request_options(runtime_opts)
      |> Req.new()
      |> ReqStep.attach()
      |> PinnedTarget.attach(addresses)

    conditional_headers = Origin.conditional_headers(previous, request)

    request = Req.merge(request, headers: conditional_headers)

    requested_at = clock.()

    case request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{
          response: response,
          origin: Origin.from_response(response, {requested_at, clock.()}),
          receive_timeout:
            option(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
        }

      {:ok, %Req.Response{status: 304} = response} ->
        cancel_response(response)
        revalidated(previous, conditional_headers, response, {requested_at, clock.()})

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        route_redirect(
          response,
          req_options,
          runtime_opts,
          validate,
          redirects_left,
          redirects_allowed?
        )

      {:ok, %Req.Response{status: status} = response} ->
        cancel_response(response)
        {:error, {:bad_status, status}}

      {:error, %Req.HTTPError{}} ->
        {:error, :invalid_body}

      {:error, _exception} ->
        {:error, :connect_error}
    end
  end

  defp request(request) do
    Req.request(request)
  rescue
    exception in Finch.Error -> {:error, exception}
  end

  defp revalidated(_previous, [], _response, _timing), do: {:error, :unexpected_not_modified}

  defp revalidated(previous, _headers, response, timing) do
    current = Origin.from_response(response, timing, previous.headers)

    with true <- Origin.matches?(previous, response.request.headers),
         {:ok, origin} <- Origin.refreshed(previous, current) do
      {:not_modified, origin}
    else
      false -> {:error, {:source, :invalid_not_modified}}
      {:error, _reason} = error -> error
    end
  end

  defp route_redirect(
         response,
         req_options,
         runtime_opts,
         validate,
         redirects_left,
         redirects_allowed?
       ) do
    location = location_header(response)
    cancel_response(response)

    cond do
      redirects_left <= 0 ->
        if redirects_allowed?,
          do: {:error, :too_many_redirects},
          else: {:error, :redirect_not_followed}

      is_nil(location) ->
        {:error, :invalid_redirect}

      true ->
        next_url =
          req_options
          |> Keyword.fetch!(:url)
          |> URI.parse()
          |> URI.merge(location)
          |> URI.to_string()

        follow(
          redirect_options(req_options, next_url),
          runtime_opts,
          validate,
          redirects_left - 1,
          redirects_allowed?
        )
    end
  end

  defp redirect_options(req_options, next_url) do
    previous = URI.parse(Keyword.fetch!(req_options, :url))
    next = URI.parse(next_url)
    opts = Keyword.put(req_options, :url, next_url)

    case {previous.scheme, String.downcase(previous.host), previous.port} ==
           {next.scheme, String.downcase(next.host || ""), next.port} do
      true ->
        opts

      false ->
        opts
        |> Keyword.drop([:auth, :aws_sigv4])
        |> Keyword.update(:headers, [], &strip_credentials/1)
    end
  end

  defp strip_credentials(headers) do
    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) in ["authorization", "proxy-authorization", "cookie"]
    end)
  end

  defp location_header(%Req.Response{} = response) do
    case Req.Response.get_header(response, "location") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp stream_response(
         %{response: %Req.Response{body: %Req.Response.Async{ref: ref}} = response} = state
       ) do
    with {:ok, message} <- next_message(ref, state.receive_timeout),
         {:ok, chunks} <- parse_message(response, message) do
      data_chunks = for {:data, data} <- chunks, do: data

      if Enum.any?(chunks, &(&1 == :done)) do
        {data_chunks, {:done, state}}
      else
        {data_chunks, state}
      end
    else
      {:error, reason} -> raise StreamError, reason: reason
      :unknown -> stream_response(state)
    end
  end

  defp next_message(ref, receive_timeout) do
    receive do
      {^ref, _message} = message -> {:ok, message}
    after
      receive_timeout -> {:error, :receive_timeout}
    end
  end

  defp parse_message(response, message) do
    case Req.parse_message(response, message) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, exception} -> {:error, stream_error(exception, response)}
      :unknown -> :unknown
    end
  end

  defp stream_error(%{__struct__: module, reason: reason}, response)
       when module in [Req.TransportError, Finch.TransportError] do
    transport_error(reason, response)
  end

  defp stream_error(_exception, _response), do: :invalid_body

  defp transport_error(:timeout, _response), do: :receive_timeout
  defp transport_error(:econnreset, _response), do: :connection_reset

  defp transport_error(:closed, response) do
    case Req.Response.get_header(response, "content-length") != [] or
           Req.Response.get_header(response, "transfer-encoding") != [] do
      true -> :truncated_body
      false -> :connection_closed
    end
  end

  defp transport_error(_reason, _response), do: :transport_error

  defp request_options(req_options, runtime_opts) do
    req_options
    |> Keyword.drop([:pool_timeout, :connect_options])
    |> Keyword.merge(
      into: :self,
      retry: false,
      redirect: false,
      receive_timeout:
        option(req_options, runtime_opts, :receive_timeout, @default_receive_timeout),
      finch: finch_options(req_options, runtime_opts)
    )
  end

  defp finch_options(req_options, runtime_opts) do
    %{host: host} = URI.parse(Keyword.fetch!(req_options, :url))
    inet6 = Keyword.get(req_options, :inet6, false) || String.contains?(host, ":")

    req_options
    |> Map.new()
    |> Map.put(:connect_options, connect_options(req_options, runtime_opts))
    |> Map.put(:inet6, inet6)
    |> Req.Finch.pool_options()
    |> Keyword.put(
      :pool_timeout,
      option(req_options, runtime_opts, :pool_timeout, @default_pool_timeout)
    )
  end

  defp connect_options(req_options, runtime_opts) do
    req_options
    |> Keyword.get(:connect_options, [])
    |> Keyword.put_new(
      :timeout,
      option(req_options, runtime_opts, :connect_timeout, @default_connect_timeout)
    )
  end

  defp option(req_options, runtime_opts, key, default) do
    Keyword.get(runtime_opts, key, Keyword.get(req_options, key, default))
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
    :ok
  rescue
    ArgumentError -> :ok
  end
end

defmodule ImagePipe.Source.ReqStream do
  @moduledoc false

  alias ImagePipe.Source.HTTP.PinnedTarget
  alias ImagePipe.Source.Origin
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry.Trace.ReqStep

  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000

  @spec open(keyword(), keyword()) ::
          {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, ImagePipe.Source.error()}
  def open(req_options, runtime_opts) do
    deadline = deadline(option(req_options, runtime_opts, :fetch_timeout, :infinity))
    runtime_opts = Keyword.put(runtime_opts, :deadline, deadline)

    case open_response(req_options, runtime_opts) do
      %{response: response, origin: origin} = state ->
        state = Map.put(state, :deadline, deadline)

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
    requested_at = clock.()

    case request(req_options, runtime_opts, previous, addresses) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        validate_response = Keyword.get(runtime_opts, :validate_response, fn _response -> :ok end)

        case validate_response.(response) do
          :ok ->
            %{
              response: response,
              origin: Origin.from_response(response, {requested_at, clock.()}),
              receive_timeout:
                option(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
            }

          {:error, reason} ->
            cancel_response(response)
            {:error, reason}
        end

      {:ok, %Req.Response{status: 304} = response} ->
        cancel_response(response)
        revalidated(previous, response, {requested_at, clock.()})

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

      {:error, exception} ->
        {:error, request_error(exception)}
    end
  end

  defp request_error(%Req.HTTPError{}), do: :invalid_body

  # An origin that accepts the connection but sends no headers in time.
  defp request_error(%{__struct__: module, reason: :timeout})
       when module in [Req.TransportError, Finch.TransportError],
       do: :receive_timeout

  defp request_error(_exception), do: :connect_error

  # An origin may close an idle kept-alive connection just as the pool hands it
  # out, so a request that fails that way before any response is sent once more,
  # rebuilt so its timeouts stay within the deadline.
  defp request(req_options, runtime_opts, previous, addresses, attempts \\ 2) do
    req_options
    |> build_request(runtime_opts, previous, addresses)
    |> send_request()
    |> case do
      {:error, %{__struct__: module, reason: reason}}
      when attempts > 1 and module in [Req.TransportError, Finch.TransportError] and
             reason in [:closed, :econnreset] ->
        request(req_options, runtime_opts, previous, addresses, attempts - 1)

      result ->
        result
    end
  end

  defp build_request(req_options, runtime_opts, previous, addresses) do
    req_options
    |> request_options(runtime_opts)
    |> Req.new()
    |> ReqStep.attach()
    |> Req.Request.append_request_steps(
      conditional_headers: &put_conditional_headers(&1, previous)
    )
    |> PinnedTarget.attach(addresses)
  end

  defp send_request(request) do
    Req.request(request)
  rescue
    exception in Finch.Error -> {:error, exception}
  end

  # Req adds headers such as authorization and user-agent in its own steps, and
  # an origin's Vary can name them, so the validators are chosen after those,
  # but before pinning replaces the logical URL.
  defp put_conditional_headers(request, previous) do
    previous
    |> Origin.conditional_headers(request)
    |> Enum.reduce(request, fn {name, value}, request ->
      Req.Request.put_header(request, name, value)
    end)
  end

  defp revalidated(previous, response, timing) do
    case conditional?(response.request) do
      true -> not_modified(previous, response, timing)
      false -> {:error, :unexpected_not_modified}
    end
  end

  defp conditional?(request) do
    Req.Request.get_header(request, "if-none-match") != [] or
      Req.Request.get_header(request, "if-modified-since") != []
  end

  defp not_modified(previous, response, timing) do
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
      ReqSanitizer.header_name(name) in ["authorization", "proxy-authorization", "cookie"]
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
    with {:ok, message} <- next_message(ref, wait_time(state)),
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

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  # The body must also finish by the deadline, however steadily the origin
  # sends, so the wait for each chunk is cut short near it.
  defp wait_time(%{deadline: :infinity, receive_timeout: timeout}), do: timeout

  defp wait_time(%{deadline: deadline, receive_timeout: timeout}),
    do: min(timeout, remaining(deadline))

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
        req_options
        |> option(runtime_opts, :receive_timeout, @default_receive_timeout)
        |> within_deadline(runtime_opts),
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
      req_options
      |> option(runtime_opts, :pool_timeout, @default_pool_timeout)
      |> within_deadline(runtime_opts)
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

  # Waiting for a pooled connection and for the response, on every redirect
  # hop, ends by the deadline. The connect timeout is part of a pinned pool's
  # identity, so it stays fixed.
  defp within_deadline(timeout, runtime_opts) do
    case Keyword.fetch!(runtime_opts, :deadline) do
      :infinity -> timeout
      deadline -> min(timeout, remaining(deadline))
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

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

defmodule ImagePipe.Source.ReqStream do
  @moduledoc false

  alias ImagePipe.Source.HTTP.PinnedTarget
  alias ImagePipe.Source.Origin
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Telemetry.Trace.ReqStep

  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000
  @default_pool_size 50

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

    case check_target(validate, url, Keyword.fetch!(runtime_opts, :deadline)) do
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

  # The target check resolves the host, which can stall for as long as the
  # resolver allows, so it too ends by the deadline.
  defp check_target(validate, url, :infinity), do: validate.(url)

  defp check_target(validate, url, deadline) do
    task = Task.async(fn -> validate.(url) end)

    case Task.yield(task, remaining(deadline)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :receive_timeout}
    end
  end

  defp request_and_route(
         req_options,
         runtime_opts,
         validate,
         redirects_left,
         redirects_allowed?,
         addresses \\ nil,
         reroute? \\ true
       ) do
    clock = Keyword.get(runtime_opts, :clock, fn -> System.system_time(:second) end)
    previous = Keyword.get(runtime_opts, :source_validation)
    requested_at = clock.()

    case request(req_options, runtime_opts, previous, addresses) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        validate_response = Keyword.get(runtime_opts, :validate_response, fn _response -> :ok end)

        with :ok <- check_length(response, Keyword.get(runtime_opts, :max_body_bytes)),
             :ok <- validate_response.(response) do
          %{
            response: response,
            origin: Origin.from_response(response, {requested_at, clock.()}),
            receive_timeout:
              option(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
          }
        else
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
        request_failed(exception, reroute? and addresses != nil, fn error ->
          reroute(
            error,
            req_options,
            runtime_opts,
            validate,
            redirects_left,
            redirects_allowed?,
            addresses
          )
        end)
    end
  end

  # The body streams into this process's mailbox whether or not anyone reads
  # it, and the body stream enforces the limit only as it's read. A declared
  # length over the limit fails before any of it arrives.
  defp check_length(_response, nil), do: :ok

  defp check_length(response, max_body_bytes) do
    with [value] <- Req.Response.get_header(response, "content-length"),
         {length, ""} when length > max_body_bytes <- Integer.parse(value) do
      {:error, :body_too_large}
    else
      _ -> :ok
    end
  end

  defp request_failed(exception, reroutable?, reroute) do
    error = {:error, request_error(exception)}
    if reroutable? and unreachable?(exception), do: reroute.(error), else: error
  end

  # Failures that a moved origin causes: nothing accepts the connection, or
  # nothing answers in time. A TLS or protocol error means the address
  # answered.
  @unreachable [:econnrefused, :ehostunreach, :enetunreach, :ehostdown, :enetdown, :timeout]

  defp unreachable?(%{__struct__: module, reason: reason})
       when module in [Req.TransportError, Finch.TransportError],
       do: reason in @unreachable

  defp unreachable?(_exception), do: false

  # The checked addresses may come from a cached answer for an origin that has
  # since moved, so when none of them is reachable, the host is looked up
  # again and a changed answer gets one more try. Otherwise the fetch fails
  # with the original error.
  defp reroute(
         error,
         req_options,
         runtime_opts,
         validate,
         redirects_left,
         redirects_allowed?,
         addresses
       ) do
    url = Keyword.fetch!(req_options, :url)
    revalidate = Keyword.get(runtime_opts, :revalidate_target, validate)

    with {:ok, fresh} <- check_target(revalidate, url, Keyword.fetch!(runtime_opts, :deadline)),
         false <- Enum.sort(fresh) == Enum.sort(addresses) do
      request_and_route(
        req_options,
        runtime_opts,
        validate,
        redirects_left,
        redirects_allowed?,
        fresh,
        false
      )
    else
      _unchanged_or_denied -> error
    end
  end

  defp request_error(:pool_timeout), do: :pool_timeout
  defp request_error(:deadline_exceeded), do: :receive_timeout
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
        deadline_spent(result, Keyword.fetch!(runtime_opts, :deadline))
    end
  end

  # Every wait for a pooled connection is capped to the time left, so a pool
  # timeout once the deadline has passed means the fetch ran out of time, not
  # that the pool was full.
  defp deadline_spent({:error, :pool_timeout} = result, deadline) when deadline != :infinity do
    if remaining(deadline) == 0, do: {:error, :deadline_exceeded}, else: result
  end

  defp deadline_spent(result, _deadline), do: result

  defp build_request(req_options, runtime_opts, previous, addresses) do
    req_options
    |> request_options(runtime_opts)
    |> Req.new()
    |> ReqStep.attach()
    |> Req.Request.append_request_steps(
      conditional_headers: &put_conditional_headers(&1, previous)
    )
    |> PinnedTarget.attach(addresses, Keyword.fetch!(runtime_opts, :deadline))
  end

  # With `into: :self`, Finch sends the response to the process that made the
  # request, from a process linked to it. When no pooled connection frees up
  # within the pool timeout, that linked process raises, which would kill the
  # caller. So a monitored relay makes the request and passes every response
  # message on, and the caller reads them as if it had made the request.
  # Requests to a test plug don't use Finch and run in the caller.
  defp send_request(%Req.Request{options: %{plug: _plug}} = request),
    do: request_in_place(request)

  defp send_request(request) do
    caller = self()
    context = RequestContext.capture()
    callers = [caller | Process.get(:"$callers", [])]

    {relay, monitor} =
      spawn_monitor(fn ->
        RequestContext.adopt(context)
        Process.put(:"$callers", callers)
        relay_request(caller, request)
      end)

    receive do
      {^relay, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {^relay, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^relay, reason} ->
        relay_exit(reason)
    end
  end

  defp relay_request(caller, request) do
    caller_monitor = Process.monitor(caller)

    result =
      try do
        request_in_place(request)
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    send(caller, {self(), result})

    case result do
      {:ok, %Req.Response{body: %Req.Response.Async{ref: ref}}} ->
        relay(caller, caller_monitor, ref)

      _other ->
        :ok
    end
  end

  # Ends after the last message, or with the caller. Cancelling the response
  # stops the linked Finch process, which ends the relay too.
  defp relay(caller, caller_monitor, ref) do
    receive do
      {^ref, message} = response_message ->
        send(caller, response_message)

        case message do
          :done -> :ok
          {:error, _reason} -> :ok
          _more -> relay(caller, caller_monitor, ref)
        end

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        exit(:shutdown)
    end
  end

  # Finch reports a full pool by raising this message in the linked process.
  defp relay_exit({%RuntimeError{message: "Finch was unable to provide a connection" <> _}, _}),
    do: {:error, :pool_timeout}

  defp relay_exit(reason), do: exit(reason)

  defp request_in_place(request) do
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
        previous = URI.parse(Keyword.fetch!(req_options, :url))
        next = URI.merge(previous, location)

        if allowed_redirect?(previous, next) do
          follow(
            redirect_options(req_options, previous, next),
            runtime_opts,
            validate,
            redirects_left - 1,
            redirects_allowed?
          )
        else
          {:error, :invalid_redirect}
        end
    end
  end

  # Req turns userinfo into Basic auth, and an https origin's redirect to
  # http would let the network replace the image.
  defp allowed_redirect?(previous, next),
    do: next.userinfo == nil and not (previous.scheme == "https" and next.scheme == "http")

  # Another origin gets only the conditional headers ImagePipe adds, since
  # any configured header, such as an API key, can be a credential.
  defp redirect_options(req_options, previous, next) do
    opts = Keyword.put(req_options, :url, URI.to_string(next))

    case origin(previous) == origin(next) do
      true ->
        opts

      false ->
        opts
        |> Keyword.drop([:auth, :aws_sigv4])
        |> Keyword.update(:headers, [], &conditional_headers/1)
    end
  end

  # URI.merge leaves the port of a protocol-relative Location unset.
  defp origin(uri),
    do: {uri.scheme, String.downcase(uri.host || ""), uri.port || URI.default_port(uri.scheme)}

  defp conditional_headers(headers) do
    Enum.filter(headers, fn {name, _value} ->
      ReqSanitizer.header_name(name) in ["if-none-match", "if-modified-since"]
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
    |> Keyword.put(:size, option(req_options, runtime_opts, :pool_size, @default_pool_size))
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

  # Also stops the relay, which an HTTP/2 cancel leaves waiting.
  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
    stop_relay(response.body)
  rescue
    ArgumentError -> :ok
  end

  defp stop_relay(%Req.Response.Async{pid: relay}) when relay != self() do
    Process.exit(relay, :shutdown)
    :ok
  end

  defp stop_relay(_body), do: :ok
end

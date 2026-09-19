defmodule ImagePipe.Source.ReqStream do
  @moduledoc false

  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry.Trace.ReqStep

  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000

  @spec stream(keyword(), keyword()) :: Enumerable.t()
  def stream(req_options, runtime_opts) when is_list(req_options) and is_list(runtime_opts) do
    Stream.resource(
      fn -> open_response(req_options, runtime_opts) end,
      fn
        %{response: %Req.Response{}} = state ->
          stream_response(state)

        {:done, %{response: %Req.Response{} = response}} ->
          {:halt, response}

        {:error, reason} ->
          raise StreamError, reason: reason
      end,
      fn
        %{response: %Req.Response{} = response} -> cancel_response(response)
        {:done, %{response: %Req.Response{} = response}} -> cancel_response(response)
        _other -> :ok
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_and_route(req_options, runtime_opts, validate, redirects_left, redirects_allowed?) do
    request =
      req_options
      |> request_options(runtime_opts)
      |> Req.new()
      |> ReqStep.attach()

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{
          response: response,
          receive_timeout:
            option(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
        }

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

      {:error, _exception} ->
        {:error, :connect_error}
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
          Keyword.put(req_options, :url, next_url),
          runtime_opts,
          validate,
          redirects_left - 1,
          redirects_allowed?
        )
    end
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
      {:error, %{reason: :timeout}} -> {:error, :receive_timeout}
      {:error, _exception} -> {:error, :invalid_body}
      :unknown -> :unknown
    end
  end

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

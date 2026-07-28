defmodule ImagePipe.SourceTest.RootHTTPAdapter do
  @moduledoc false

  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.StreamError

  @impl Source
  def validate_options(opts) when is_list(opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    req_options = Keyword.get(opts, :req_options, [])
    internal_cache = Keyword.get(opts, :internal_cache, :enabled)
    # `:none` (default) leaves the source without a byte identity; `:strong`
    # gives it a stable one so a dialect emits an ETag — the shape ETag/304
    # wire tests need.
    byte_identity = Keyword.get(opts, :byte_identity, :none)

    {:ok,
     [
       root_url: root_url,
       req_options: req_options,
       internal_cache: internal_cache,
       byte_identity: byte_identity
     ]}
  end

  @impl Source
  def resolve(%SourcePath{segments: segments}, opts, _runtime_opts) do
    root_url = Keyword.fetch!(opts, :root_url)

    identity = [
      kind: :path,
      adapter: :test_http_root,
      root: root_url,
      path: segments
    ]

    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: identity,
       internal_cache: Keyword.fetch!(opts, :internal_cache),
       http_cache: :inherit,
       cache_semantics: cache_semantics(Keyword.fetch!(opts, :byte_identity), identity),
       fetch: [
         url: build_url(root_url, segments),
         req_options: Keyword.fetch!(opts, :req_options)
       ]
     }}
  end

  defp cache_semantics(:none, _identity),
    do: %CacheSemantics{byte_identity: :none, stable?: false}

  defp cache_semantics(:strong, identity),
    do: %CacheSemantics{byte_identity: {:strong, identity}, stable?: true}

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, runtime_opts) do
    req_options =
      fetch
      |> Keyword.fetch!(:req_options)
      |> Keyword.merge(url: Keyword.fetch!(fetch, :url), method: :get, max_redirects: 0)

    {:ok, %Response{stream: request_stream(req_options, runtime_opts)}}
  end

  defp build_url(root_url, segments) do
    path =
      Enum.map_join(segments, "/", fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    root_url = String.trim_trailing(root_url, "/")
    root_url <> "/" <> path
  end

  defp request_stream(req_options, runtime_opts) do
    receive_timeout = Keyword.get(runtime_opts, :receive_timeout, 5_000)

    Stream.resource(
      fn -> open_response(req_options, receive_timeout) end,
      fn
        %{response: %Req.Response{}} = state -> stream_response(state)
        {:done, %{response: %Req.Response{} = response}} -> {:halt, response}
        {:error, reason} -> raise StreamError, reason: reason
      end,
      fn
        %{response: %Req.Response{} = response} -> cancel_response(response)
        {:done, %{response: %Req.Response{} = response}} -> cancel_response(response)
        _other -> :ok
      end
    )
  end

  defp open_response(req_options, receive_timeout) do
    case Req.get(Keyword.merge(req_options, into: :self, retry: false),
           receive_timeout: receive_timeout
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{response: response, receive_timeout: receive_timeout}

      {:ok, %Req.Response{status: status} = response} ->
        cancel_response(response)
        {:error, {:bad_status, status}}

      {:error, _exception} ->
        {:error, :connect_error}
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
      {:error, _exception} -> {:error, :invalid_body}
      :unknown -> :unknown
    end
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
    :ok
  rescue
    ArgumentError -> :ok
  end
end

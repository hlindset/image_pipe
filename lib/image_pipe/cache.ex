defmodule ImagePipe.Cache do
  @moduledoc """
  Coordinates cache lookups and writes for processed image responses.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.MaterialDigest,
      ImagePipe.Plan,
      ImagePipe.Output,
      ImagePipe.Telemetry
    ],
    exports: [
      Entry,
      Key,
      FileSystem
    ]

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Sink
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan

  @shared_cache_option_keys [:key_headers, :key_cookies, :max_body_bytes]
  @plan_key_option_keys [
    :auto_jpeg_xl,
    :auto_avif,
    :auto_webp,
    :output_capabilities,
    :detector_identity
  ]
  @required_adapter_callbacks [
    get: 2,
    open_sink: 3,
    write_chunk: 3,
    commit_sink: 2,
    abort_sink: 2
  ]
  @shared_cache_option_schema NimbleOptions.new!(
                                key_headers: [
                                  type: {:list, :string}
                                ],
                                key_cookies: [
                                  type: {:list, :string}
                                ],
                                max_body_bytes: [
                                  type: {:or, [nil, :non_neg_integer]}
                                ]
                              )

  @callback get(Key.t(), keyword()) :: {:hit, Entry.t()} | :miss | {:error, term()}
  @callback open_sink(Key.t(), Entry.Metadata.t(), keyword()) ::
              {:ok, state()} | {:error, term()}
  @callback write_chunk(state(), binary(), keyword()) ::
              {:ok, state()} | {:error, term(), state()}
  @callback commit_sink(state(), keyword()) :: :ok | {:ok, :rejected} | {:error, term()}
  @callback abort_sink(state(), keyword()) :: :ok | {:error, term()}
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @optional_callbacks validate_options: 1

  @type state :: term()
  @opaque sink :: Sink.t()

  @type lookup_result ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:miss, Key.t(), {:cache_read, term()}}

  @doc false
  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, term()}
  def validate_config(opts) when is_list(opts) do
    normalize_config(opts)
  end

  @doc false
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} -> opts
      {:error, reason} -> raise ArgumentError, "invalid cache config: #{inspect(reason)}"
    end
  end

  @doc false
  def shared_option_keys, do: @shared_cache_option_keys

  @doc false
  @spec lookup(Plug.Conn.t(), Plan.t(), term(), keyword()) :: lookup_result()
  def lookup(conn, %Plan{} = plan, source_identity, opts) when is_list(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        :disabled

      {adapter, cache_opts} ->
        lookup_configured(adapter, conn, plan, source_identity, opts, cache_opts)
    end
  end

  @doc false
  @spec open_sink(Key.t() | nil, Resolved.t(), keyword()) :: sink() | nil
  def open_sink(nil, %Resolved{}, _opts), do: nil

  def open_sink(%Key{} = key, %Resolved{} = resolved_output, opts) when is_list(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      {adapter, cache_opts} ->
        Sink.open(adapter, key, resolved_output, cache_opts, opts)
    end
  end

  @doc false
  @spec write_chunk(sink() | nil, binary(), keyword()) :: sink() | nil
  def write_chunk(sink, chunk, opts) when is_binary(chunk),
    do: Sink.write_chunk(sink, chunk, opts)

  @doc false
  @spec commit_sink(sink() | nil, keyword()) :: :ok
  def commit_sink(sink, opts), do: Sink.commit(sink, opts)

  @doc false
  @spec abort_sink(sink() | nil, atom(), keyword()) :: :ok
  def abort_sink(sink, reason, opts), do: Sink.abort(sink, reason, opts)

  defp normalize_config(opts) do
    case Keyword.fetch(opts, :cache) do
      :error ->
        {:ok, opts}

      {:ok, {adapter, cache_opts}} when is_list(cache_opts) ->
        with {:ok, adapter, cache_opts} <- validate_configured_cache(adapter, cache_opts) do
          {:ok, Keyword.put(opts, :cache, {adapter, cache_opts})}
        end

      {:ok, invalid} ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp lookup_configured(adapter, conn, plan, source_identity, opts, cache_opts) do
    {:ok, key} = Key.build(conn, plan, source_identity, key_options(opts, cache_opts))
    get_configured(adapter, key, cache_opts)
  end

  defp get_configured(adapter, key, cache_opts) do
    case adapter.get(key, cache_opts) do
      {:hit, %Entry{} = entry} ->
        handle_hit(entry, key, cache_opts)

      :miss ->
        {:miss, key}

      {:error, reason} ->
        handle_read_error(reason, key, cache_opts)

      unexpected ->
        handle_read_error({:invalid_adapter_result, unexpected}, key, cache_opts)
    end
  rescue
    exception -> handle_read_error(exception, key, cache_opts)
  end

  defp handle_hit(%Entry{} = entry, key, cache_opts) do
    case Entry.validate(entry) do
      :ok -> {:hit, key, entry}
      {:error, reason} -> handle_read_error({:invalid_entry, reason}, key, cache_opts)
    end
  end

  defp validate_configured_cache(adapter, cache_opts) do
    with :ok <- validate_cache_opts(adapter, cache_opts),
         :ok <- validate_adapter(adapter),
         {:ok, shared_opts} <- normalize_shared_options(cache_opts),
         {:ok, adapter_opts} <- normalize_adapter_options(adapter, adapter_options(cache_opts)) do
      {:ok, adapter, Keyword.merge(shared_opts, adapter_opts)}
    end
  end

  defp validate_cache_opts(adapter, cache_opts) do
    if Keyword.keyword?(cache_opts),
      do: :ok,
      else: {:error, {:invalid_cache_config, {adapter, cache_opts}}}
  end

  defp validate_adapter(adapter) when is_atom(adapter) do
    with {:module, _module} <- Code.ensure_loaded(adapter),
         [] <- missing_adapter_callbacks(adapter) do
      :ok
    else
      {:error, _reason} -> {:error, {:invalid_cache_config, {:adapter, adapter}}}
      missing -> {:error, {:invalid_cache_config, {:adapter_missing_callbacks, adapter, missing}}}
    end
  end

  defp validate_adapter(adapter), do: {:error, {:invalid_cache_config, {:adapter, adapter}}}

  defp missing_adapter_callbacks(adapter) do
    Enum.reject(@required_adapter_callbacks, fn {function, arity} ->
      function_exported?(adapter, function, arity)
    end)
  end

  defp normalize_shared_options(cache_opts) do
    shared_opts = Keyword.take(cache_opts, @shared_cache_option_keys)

    case NimbleOptions.validate(shared_opts, @shared_cache_option_schema) do
      {:ok, validated_shared_opts} ->
        reject_reserved_key_headers(validated_shared_opts)

      {:error, error} ->
        {:error, {:invalid_cache_config, shared_validation_error(error)}}
    end
  end

  defp reject_reserved_key_headers(shared_opts) do
    key_headers = Keyword.get(shared_opts, :key_headers, [])

    if Enum.any?(key_headers, &(String.downcase(&1) == "accept")) do
      {:error, {:invalid_cache_config, {:key_headers, ~s(cannot include "accept")}}}
    else
      {:ok, shared_opts}
    end
  end

  defp shared_validation_error(%NimbleOptions.ValidationError{key: key, value: value})
       when key in @shared_cache_option_keys do
    {key, value}
  end

  defp adapter_options(cache_opts), do: Keyword.drop(cache_opts, @shared_cache_option_keys)

  defp normalize_adapter_options(adapter, cache_opts) do
    if function_exported?(adapter, :validate_options, 1) do
      case adapter.validate_options(cache_opts) do
        {:ok, normalized_opts} when is_list(normalized_opts) -> {:ok, normalized_opts}
        {:error, reason} -> {:error, {:invalid_cache_config, reason}}
        unexpected -> {:error, {:invalid_cache_config, {:adapter_options, unexpected}}}
      end
    else
      {:ok, cache_opts}
    end
  end

  defp handle_read_error(reason, key, _cache_opts) do
    Logger.warning("cache read error: #{inspect(reason)}")
    {:miss, key, {:cache_read, reason}}
  end

  defp key_options(opts, cache_opts) do
    cache_opts
    |> Keyword.take([:key_headers, :key_cookies])
    |> Keyword.merge(Keyword.take(opts, @plan_key_option_keys))
  end
end

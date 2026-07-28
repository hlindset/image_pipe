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
  alias ImagePipe.Error
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry

  @shared_cache_option_keys [:max_body_bytes]
  @removed_cache_option_keys [:key_headers, :key_cookies]
  @required_adapter_callbacks [
    get: 2,
    open_sink: 3,
    write_chunk: 3,
    commit_sink: 2,
    abort_sink: 2
  ]
  @shared_cache_option_schema NimbleOptions.new!(
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

  @type entry_lookup_result ::
          :disabled
          | {:hit, Entry.t()}
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

  @doc """
  Looks up the entry stored under `key`, dispatching to the configured adapter
  and failing open on a read error. A dialect builds its own
  `%ImagePipe.Cache.Key{}` via `ImagePipe.Representation.build/3` and looks it
  up directly.
  """
  @spec lookup_entry(Key.t(), keyword()) :: entry_lookup_result()
  def lookup_entry(%Key{} = key, opts) when is_list(opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:cache, :lookup],
      entry_lookup_start_metadata(opts),
      fn ->
        result =
          case Keyword.get(opts, :cache) do
            nil ->
              :disabled

            {adapter, cache_opts} ->
              get_entry_configured(adapter, key, cache_opts)
          end

        {result, entry_lookup_stop_metadata(result)}
      end
    )
  end

  @doc false
  @spec open_sink(Key.t() | nil, Resolved.t() | {:complete_body, String.t()}, keyword()) ::
          sink() | nil
  def open_sink(nil, %Resolved{}, _opts), do: nil
  def open_sink(nil, {:complete_body, _content_type}, _opts), do: nil

  def open_sink(%Key{} = key, %Resolved{} = resolved_output, opts) when is_list(opts) do
    dispatch_open_sink(key, resolved_output, opts)
  end

  def open_sink(%Key{} = key, {:complete_body, content_type} = target, opts)
      when is_list(opts) and is_binary(content_type) do
    dispatch_open_sink(key, target, opts)
  end

  defp dispatch_open_sink(key, sink_target, opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      {adapter, cache_opts} ->
        Sink.open(adapter, key, sink_target, cache_opts, opts)
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

  defp get_entry_configured(adapter, key, cache_opts) do
    case fetch_entry(adapter, key, cache_opts) do
      {:hit, entry} -> {:hit, entry}
      :miss -> {:miss, key}
      {:error, reason} -> handle_read_error(reason, key, cache_opts)
    end
  end

  defp fetch_entry(adapter, key, cache_opts) do
    case adapter.get(key, cache_opts) do
      {:hit, %Entry{} = entry} -> validate_fetched_entry(entry)
      :miss -> :miss
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:invalid_adapter_result, unexpected}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp validate_fetched_entry(%Entry{} = entry) do
    case Entry.validate(entry) do
      :ok -> {:hit, entry}
      {:error, reason} -> {:error, {:invalid_entry, reason}}
    end
  end

  defp validate_configured_cache(adapter, cache_opts) do
    with :ok <- validate_cache_opts(adapter, cache_opts),
         :ok <- reject_removed_options(cache_opts),
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

  defp reject_removed_options(cache_opts) do
    case Enum.find(@removed_cache_option_keys, &Keyword.has_key?(cache_opts, &1)) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "cache option #{inspect(key)} was removed; partition on request headers and cookies " <>
                "with the mount-level storage_inputs: [{:header, name}, {:cookie, name}]"
    end
  end

  defp normalize_shared_options(cache_opts) do
    shared_opts = Keyword.take(cache_opts, @shared_cache_option_keys)

    case NimbleOptions.validate(shared_opts, @shared_cache_option_schema) do
      {:ok, validated_shared_opts} ->
        {:ok, validated_shared_opts}

      {:error, error} ->
        {:error, {:invalid_cache_config, shared_validation_error(error)}}
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

  defp entry_lookup_start_metadata(opts) do
    cache =
      case Keyword.get(opts, :cache) do
        nil -> :disabled
        _cache -> nil
      end

    %{cache: cache}
  end

  defp entry_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}
  defp entry_lookup_stop_metadata({:hit, %Entry{}}), do: %{result: :ok, cache: :hit}
  defp entry_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp entry_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Error.tag(error)}
end

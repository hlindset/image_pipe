defmodule ImagePipe.Cache do
  # Coordinates cache lookups and writes for processed image responses.
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.SafePath,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    exports: [
      Entry,
      File,
      Input,
      Resources,
      Work,
      OutputWork,
      Key,
      FileSystem,
      FileSystem.CheckedDirs
    ]

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Cache.FileSystem.Toucher
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Sink
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.Skipped
  alias ImagePipe.Telemetry

  @shared_cache_option_keys [:max_body_bytes]
  @shared_cache_option_schema NimbleOptions.new!(
                                max_body_bytes: [
                                  type: {:or, [nil, :non_neg_integer]}
                                ]
                              )

  @doc false
  def shared_options_schema, do: @shared_cache_option_schema.schema

  @opaque sink :: Sink.t()

  @type entry_lookup_result ::
          :disabled
          | {:hit, Entry.t()}
          | {:miss, Key.t()}
          | {:miss, Key.t(), {:cache_read, term()}}

  @doc false
  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, term()} | no_return()
  def validate_config(opts) when is_list(opts) do
    with {:ok, opts} <- normalize_config(opts), do: Input.validate_config(opts)
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
  # Removes staged originals a VM that died left behind.
  def sweep_staged, do: Sweep.run_staged(Input.staging_dir(), [])

  @doc false
  # Sweeps the staging directory at start and periodically after.
  def staged_sweep_spec,
    do: {PeriodicSweep, id: {Sweep, :staged}, sweep: {__MODULE__, :sweep_staged, []}}

  @doc false
  # Upkeep an instance runs for its caches: the toucher that records reads,
  # and periodic cleanup for unbounded caches. A bounded cache's Admission
  # sweeps on each re-scan. A cache used without an instance gets neither.
  @spec startup_specs(keyword()) :: [Supervisor.child_spec()]
  def startup_specs(options) do
    for key <- [:cache, :input_cache],
        cache_opts = Keyword.get(options, key),
        cache_opts != nil,
        spec <- [Toucher.child_spec(cache_opts) | sweep_specs(cache_opts)],
        do: spec
  end

  defp sweep_specs(cache_opts) do
    if Keyword.has_key?(cache_opts, :max_size_bytes), do: [], else: [Store.sweep_spec(cache_opts)]
  end

  @doc false
  # Processes the configured bounded caches need. Takes resolved
  # configuration options.
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options) do
    for key <- [:cache, :input_cache],
        cache_opts = Keyword.get(options, key),
        cache_opts != nil,
        spec = FileSystem.child_spec(cache_opts),
        spec != nil,
        do: Supervisor.child_spec(spec, [])
  end

  @doc false
  def source_record(input_key, opts) do
    key = source_index_key(input_key)

    lookup = fn
      nil -> :disabled
      cache_opts -> read_source_record(key, cache_opts)
    end

    case traced_lookup(key, :source_record, opts, lookup) do
      {:hit, record} -> record
      _miss -> nil
    end
  end

  defp read_source_record(key, cache_opts) do
    case FileSystem.source_record(key, cache_opts) do
      :miss -> {:miss, key}
      {:error, reason} -> handle_read_error(reason, key, cache_opts)
      hit -> hit
    end
  end

  @doc false
  def remember_source(input_key, record, opts) do
    body = :erlang.term_to_binary(record, [:deterministic])

    source_index_key(input_key)
    |> open_sink(
      {:complete_body, "application/vnd.imagepipe.source"},
      [source_record: record],
      opts
    )
    |> write_chunk(body, opts)
    |> commit_sink(opts)
  end

  defp source_index_key(%Key{hash: hash}) do
    digest = :crypto.hash(:sha256, "source-record:" <> hash) |> Base.encode16(case: :lower)
    %Key{hash: digest, data: []}
  end

  @doc """
  Looks up `key` in the configured cache, treating read errors as misses.
  The request runner builds the key with `ImagePipe.Representation.build/3`.
  """
  @spec lookup_entry(Key.t(), keyword()) :: entry_lookup_result()
  def lookup_entry(%Key{} = key, opts) when is_list(opts) do
    traced_lookup(key, :response, opts, fn
      nil -> :disabled
      cache_opts -> get_entry(key, cache_opts)
    end)
  end

  # `entry` says what the lookup reads: a processed response, or the record
  # of the original it was made from.
  defp traced_lookup(%Key{} = key, entry, opts, lookup) do
    cache_opts = Keyword.get(opts, :cache)
    identity = %{cache_key: key.hash, entry: entry}

    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:cache, :lookup],
      Map.merge(entry_lookup_start_metadata(cache_opts), identity),
      fn ->
        result = lookup.(cache_opts)
        {result, Map.merge(entry_lookup_stop_metadata(result), identity)}
      end
    )
  end

  # `facts` describe the entry being stored: its generation cost (`:cost_us`),
  # debug facts (`:debug`) and the source record it was made from
  # (`:source_record`). Each is optional.
  @doc false
  @spec open_sink(
          Key.t() | nil,
          Resolved.t() | Skipped.t() | {:complete_body, String.t()},
          keyword(),
          keyword()
        ) ::
          sink() | nil
  def open_sink(_key, %Skipped{}, _facts, _opts), do: nil
  def open_sink(_key, %Resolved{degraded?: true}, _facts, _opts), do: nil
  def open_sink(nil, %Resolved{}, _facts, _opts), do: nil
  def open_sink(nil, {:complete_body, _content_type}, _facts, _opts), do: nil

  def open_sink(%Key{} = key, %Resolved{} = resolved_output, facts, opts) when is_list(opts) do
    dispatch_open_sink(key, resolved_output, facts, opts)
  end

  def open_sink(%Key{} = key, {:complete_body, content_type} = target, facts, opts)
      when is_list(opts) and is_binary(content_type) do
    dispatch_open_sink(key, target, facts, opts)
  end

  defp dispatch_open_sink(key, sink_target, facts, opts) do
    case Keyword.get(opts, :cache) do
      nil -> nil
      cache_opts -> Sink.open(key, sink_target, cache_opts, facts, opts)
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

      {:ok, cache_opts} when is_list(cache_opts) ->
        with {:ok, cache_opts} <- validate_configured_cache(cache_opts) do
          {:ok, Keyword.put(opts, :cache, cache_opts)}
        end

      {:ok, invalid} ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp get_entry(key, cache_opts) do
    case FileSystem.open(key, cache_opts) do
      {:hit, entry} -> {:hit, entry}
      :miss -> {:miss, key}
      {:error, reason} -> handle_read_error(reason, key, cache_opts)
    end
  end

  defp validate_configured_cache(cache_opts) do
    with :ok <- validate_cache_opts(cache_opts),
         {:ok, shared_opts} <- normalize_shared_options(cache_opts),
         {:ok, store_opts} <- normalize_store_options(store_options(cache_opts)) do
      {:ok, Keyword.merge(shared_opts, store_opts)}
    end
  end

  defp validate_cache_opts(cache_opts) do
    if Keyword.keyword?(cache_opts),
      do: :ok,
      else: {:error, {:invalid_cache_config, cache_opts}}
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

  defp store_options(cache_opts), do: Keyword.drop(cache_opts, @shared_cache_option_keys)

  defp normalize_store_options(cache_opts) do
    case FileSystem.validate_options(cache_opts) do
      {:ok, normalized_opts} -> {:ok, normalized_opts}
      {:error, reason} -> {:error, {:invalid_cache_config, reason}}
    end
  end

  defp handle_read_error(reason, key, _cache_opts) do
    Logger.warning("cache read error: #{inspect(reason)}")
    {:miss, key, {:cache_read, reason}}
  end

  defp entry_lookup_start_metadata(nil), do: %{cache: :disabled, pool: :output}
  defp entry_lookup_start_metadata(_cache_opts), do: %{cache: nil, pool: :output}

  defp entry_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}
  defp entry_lookup_stop_metadata({:hit, _entry_or_record}), do: %{result: :ok, cache: :hit}
  defp entry_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp entry_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Telemetry.error_tag(error)}
end

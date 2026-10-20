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
      Cost,
      Entry,
      File,
      Input,
      Resources,
      Work,
      OutputWork,
      Key,
      FileSystem,
      FileSystem.CheckedDirs,
      FileSystem.RefusedRoots
    ]

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.PeriodicSweep
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Lookups
  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Cache.Sink
  alias ImagePipe.Cache.SourceRecords
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
  # The processes an instance runs for its caches: the claim on each root,
  # Admission, and periodic cleanup, and the instance's in-memory source
  # records. Takes resolved configuration options.
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options) do
    # The cache's own events, such as admission and eviction, use the
    # instance's prefix.
    telemetry = Keyword.take(options, [:telemetry_prefix])

    caches =
      for key <- [:cache, :input_cache],
          cache_opts = Keyword.get(options, key),
          cache_opts != nil,
          do: FileSystem.child_spec(Keyword.merge(cache_opts, telemetry))

    case Keyword.get(options, :source_records) do
      nil -> caches
      table -> [{SourceRecords, table} | caches]
    end
  end

  @doc false
  # An instance keeps the records of its originals in memory, in a table
  # named after it, so an unchanged local file is hashed once rather than on
  # every request.
  @spec put_source_records(keyword(), atom()) :: keyword()
  def put_source_records(options, instance),
    do: Keyword.put(options, :source_records, Module.concat(instance, SourceRecords))

  @doc false
  # Removes the caches whose root another node holds, so requests run
  # without them (see `Owner`).
  @spec drop_refused(keyword()) :: keyword()
  def drop_refused(options) do
    Enum.reject(options, fn
      {key, cache_opts} when key in [:cache, :input_cache] and is_list(cache_opts) ->
        Owner.refused?(Store.root_dir(cache_opts))

      _other ->
        false
    end)
  end

  @doc false
  def source_record(input_key, opts) do
    lookup = fn
      nil -> :disabled
      {:memory, table} -> memory_source_record(input_key, table)
    end

    case traced_lookup(input_key, :source_record, record_store(opts), opts, lookup) do
      {:hit, record} -> record
      _miss -> nil
    end
  end

  defp memory_source_record(key, table) do
    case SourceRecords.get(table, key.hash) do
      nil -> {:miss, key}
      record -> {:hit, record}
    end
  end

  # Source records live in the instance's in-memory table, apart from the
  # caches, so they never compete with processed images for space.
  defp record_store(opts) do
    case Keyword.get(opts, :source_records) do
      nil -> nil
      table -> {:memory, table}
    end
  end

  @doc false
  # Stores the record from the calling process, a publication that already
  # runs off the request, so the record is in place when it releases the
  # source's lease.
  def remember_source(input_key, record, opts) do
    case record_store(opts) do
      nil ->
        :ok

      {:memory, table} ->
        limit = Keyword.fetch!(opts, :max_remembered_originals)
        SourceRecords.put(table, input_key.hash, record, limit)
    end
  end

  @doc """
  Looks up `key` in the configured cache, treating read errors as misses.
  The request runner builds the key with `ImagePipe.Representation.build/3`.
  It counts the outcome for `stats/1`, and a miss toward admitting the
  entry once it's written. A request that looks again, after waiting for
  another request to write the entry, uses `recheck_entry/2`, so a request
  counts once for each key it looks up.
  """
  @spec lookup_entry(Key.t(), keyword()) :: entry_lookup_result()
  def lookup_entry(%Key{} = key, opts) when is_list(opts) do
    traced_lookup(key, :response, Keyword.get(opts, :cache), opts, fn
      nil ->
        :disabled

      cache_opts ->
        key
        |> get_entry(cache_opts)
        |> tap(&count_lookup(&1, cache_opts))
        |> tap(&count_miss(&1, key, cache_opts))
    end)
  end

  defp count_miss({:hit, _entry}, _key, _cache_opts), do: :ok
  defp count_miss(_miss, key, cache_opts), do: FileSystem.missed(key, cache_opts)

  @doc "Looks up `key` like `lookup_entry/2`, without counting the outcome."
  @spec recheck_entry(Key.t(), keyword()) :: entry_lookup_result()
  def recheck_entry(%Key{} = key, opts) when is_list(opts) do
    traced_lookup(key, :response, Keyword.get(opts, :cache), opts, fn
      nil -> :disabled
      cache_opts -> get_entry(key, cache_opts, false)
    end)
  end

  defp count_lookup({:hit, _entry}, cache_opts), do: Lookups.count(cache_opts, :hit)
  defp count_lookup({:miss, _key}, cache_opts), do: Lookups.count(cache_opts, :miss)
  # A read error is served as a miss, and counted as both.
  defp count_lookup({:miss, _key, _error}, cache_opts) do
    Lookups.count(cache_opts, :miss)
    Lookups.count(cache_opts, :read_error)
  end

  @doc false
  # Usage and lookups since start of each cache in `options`. A cache another
  # node holds has only `refused` and `max_bytes`.
  @spec stats(keyword()) :: %{optional(:output | :input) => map()}
  def stats(options) do
    for {key, name} <- [cache: :output, input_cache: :input],
        cache_opts = Keyword.get(options, key),
        cache_opts != nil,
        {:ok, stats} <- [cache_stats(cache_opts)],
        into: %{},
        do: {name, stats}
  end

  # A cache another node holds isn't used here, so it has no counts.
  defp cache_stats(cache_opts) do
    root = Store.root_dir(cache_opts)

    if Owner.refused?(root) do
      {:ok, %{refused: true, max_bytes: Keyword.fetch!(cache_opts, :max_size_bytes)}}
    else
      with {:ok, usage} <- FileSystem.usage(cache_opts),
           do: {:ok, usage |> Map.merge(Lookups.read(root)) |> Map.put(:refused, false)}
    end
  end

  # `entry` says what the lookup reads: a processed response, or the record
  # of the original it was made from. `store` is where it reads it.
  defp traced_lookup(%Key{} = key, entry, store, opts, lookup) do
    identity = %{cache_key: key.hash, entry: entry}

    Telemetry.span(
      opts,
      [:cache, :lookup],
      Map.merge(entry_lookup_start_metadata(store), identity),
      fn ->
        result = lookup.(store)
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
  defdelegate publish(hash, lease, write, opts), to: ImagePipe.Cache.Publication

  @doc false
  # Hands the write, and the output lease when given, to the cache's writer.
  @spec commit_sink(sink() | nil, keyword(), OutputWork.lease() | nil) :: :ok
  def commit_sink(sink, opts, lease \\ nil), do: Sink.commit(sink, opts, lease)

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

  defp get_entry(key, cache_opts, sighting? \\ true) do
    case FileSystem.open(key, cache_opts, sighting?) do
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
  defp entry_lookup_start_metadata({:memory, _table}), do: %{cache: nil, pool: :memory}
  defp entry_lookup_start_metadata(_cache_opts), do: %{cache: nil, pool: :output}

  defp entry_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}

  defp entry_lookup_stop_metadata({:hit, %Entry{body: %ImagePipe.Cache.File{size: size}}}),
    do: %{result: :ok, cache: :hit, bytes: size}

  defp entry_lookup_stop_metadata({:hit, _record}), do: %{result: :ok, cache: :hit}
  defp entry_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp entry_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Telemetry.error_tag(error)}
end

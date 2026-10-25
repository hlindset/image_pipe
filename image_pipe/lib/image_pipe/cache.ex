defmodule ImagePipe.Cache do
  # Coordinates cache lookups and writes for processed image responses.
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.RawFile,
      ImagePipe.SafePath,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    exports: [
      Cost,
      Entry,
      File,
      Work,
      OutputWork,
      Key,
      FileSystem,
      FileSystem.CheckedDirs,
      FileSystem.PeriodicSweep,
      FileSystem.RefusedRoots
    ]

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Lookups
  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Cache.RecentTable
  alias ImagePipe.Cache.Sink
  alias ImagePipe.Cache.SourceRecords
  alias ImagePipe.Cache.WatermarkBytes
  alias ImagePipe.Cache.Work
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
  def validate_config(opts) when is_list(opts), do: normalize_config(opts)

  @doc false
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} -> opts
      {:error, reason} -> raise ArgumentError, "invalid cache config: #{inspect(reason)}"
    end
  end

  @doc false
  # The processes an instance runs for its cache: the claim on its root,
  # Admission, and periodic cleanup, and the instance's in-memory tables.
  # Takes resolved configuration options.
  @spec child_specs(keyword()) :: [Supervisor.child_spec()]
  def child_specs(options) do
    # The cache's own events, such as admission and eviction, use the
    # instance's prefix.
    telemetry = Keyword.take(options, [:telemetry_prefix])

    caches =
      case Keyword.get(options, :cache) do
        nil -> []
        cache_opts -> [FileSystem.child_spec(Keyword.merge(cache_opts, telemetry))]
      end

    tables =
      for key <- [:source_records, :watermark_bytes],
          table = Keyword.get(options, key),
          table != nil,
          do: {RecentTable, table}

    tables ++ caches
  end

  @doc false
  # An instance keeps the records of its originals in memory, in a table
  # named after it, so an unchanged local file is hashed once rather than on
  # every request. Unless set, the table holds one record for each 50 KB the
  # output cache may store, so it doesn't forget originals whose processed
  # images are still cached, from 10,000 to 200,000 records. A record takes
  # about 1 KB for a local file and 1.4 KB for an origin image, so at most
  # about 280 MB. A second table keeps the bytes of its recently used
  # watermark assets (`WatermarkBytes`).
  @spec put_source_records(keyword(), atom()) :: keyword()
  def put_source_records(options, instance) do
    options
    |> Keyword.put(:source_records, Module.concat(instance, SourceRecords))
    |> Keyword.put(:watermark_bytes, Module.concat(instance, WatermarkBytes))
    |> Keyword.put_new_lazy(:max_remembered_originals, fn ->
      max_size_bytes = get_in(options, [:cache, :max_size_bytes]) || 0
      max_size_bytes |> div(50_000) |> max(10_000) |> min(200_000)
    end)
  end

  @doc false
  # Removes the cache when another node holds its root, so requests run
  # without it (see `Owner`).
  @spec drop_refused(keyword()) :: keyword()
  def drop_refused(options) do
    Enum.reject(options, fn
      {:cache, cache_opts} when is_list(cache_opts) ->
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
  # The bytes of the watermark asset at `input_key` whose identity is
  # `byte_identity`, or nil.
  def watermark_bytes(%Key{hash: hash}, byte_identity, opts) do
    case Keyword.get(opts, :watermark_bytes) do
      nil -> nil
      table -> WatermarkBytes.get(table, hash, byte_identity)
    end
  end

  def remember_watermark_bytes(%Key{hash: hash}, byte_identity, bytes, opts) do
    case Keyword.get(opts, :watermark_bytes) do
      nil -> :ok
      table -> WatermarkBytes.put(table, hash, byte_identity, bytes)
    end
  end

  # Stores the record from the calling process, under the source's
  # publication lock, so the record is in place when it releases the source's
  # lease.
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
        |> get_entry(cache_opts, true, remembered?(opts))
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
      cache_opts -> get_entry(key, cache_opts, false, remembered?(opts))
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
  # Usage and lookups since start of the cache in `options`. A cache another
  # node holds has only `refused` and `max_bytes`. A cache whose Admission
  # doesn't answer has no usage. `originals` counts the remembered originals.
  @spec stats(keyword()) :: %{optional(:output) => map(), optional(:originals) => map()}
  def stats(options) do
    caches =
      case Keyword.get(options, :cache) do
        nil -> %{}
        cache_opts -> %{output: cache_stats(cache_opts)}
      end

    case Keyword.get(options, :source_records) do
      nil ->
        caches

      table ->
        originals = %{
          entries: SourceRecords.size(table),
          max_entries: Keyword.fetch!(options, :max_remembered_originals)
        }

        Map.put(caches, :originals, originals)
    end
  end

  # A cache another node holds isn't used here, so it has no counts.
  defp cache_stats(cache_opts) do
    root = Store.root_dir(cache_opts)
    max_bytes = Keyword.fetch!(cache_opts, :max_size_bytes)

    if Owner.refused?(root) do
      %{refused: true, max_bytes: max_bytes}
    else
      usage =
        case FileSystem.usage(cache_opts) do
          {:ok, usage} -> Map.put(usage, :available, true)
          _unavailable -> %{available: false, max_bytes: max_bytes}
        end

      usage |> Map.merge(Lookups.read(root)) |> Map.put(:refused, false)
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

  # `facts` describe the entry being stored: its generation cost (`:cost_us`)
  # and debug facts (`:debug`). Each is optional.
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
  # Runs a source fetch's writes to memory. A leased fetch's run under the
  # source's publication lock, so they never interleave with another leased
  # fetch's for the same source, and a lease that is no longer current skips
  # them. An invalidation always runs, since dropping a record is always safe.
  def publish(hash, _lease, {:invalidate, fun}), do: publish_with(hash, nil, fun)
  def publish(hash, lease, fun) when is_function(fun, 0), do: publish_with(hash, lease, fun)

  defp publish_with(hash, lease, fun) do
    _result = Work.publish(hash, lease, fun)
    :ok
  end

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

  # A debug request needs the entry's stored debug facts, which the cache
  # doesn't keep in memory.
  defp remembered?(opts), do: not Keyword.get(opts, :debug?, false)

  defp get_entry(key, cache_opts, sighting?, remembered?) do
    case FileSystem.open(key, cache_opts, sighting?, remembered?) do
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

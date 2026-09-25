defmodule ImagePipe.Cache.SharedFileSystem do
  @moduledoc """
  Cache originals and encoded responses across independently owned directories
  on a shared filesystem. Each runtime owns a unique writer incarnation.

  Start `{ImagePipe.Cache.SharedFileSystem, name: MyCache, root: shared_path,
  local_root: local_path}` before serving requests, then configure
  `cache: {ImagePipe.Cache.SharedFileSystem, runtime: MyCache}`. Add the same
  `input_cache` configuration to retain originals. Output-only configurations
  still use this runtime for source validation state.

  `local_root` must be node-local storage outside the shared root. Acquired
  originals remain stable until released. `max_retained_bytes` (128 MiB by
  default) and `max_retained_entries` (4,096) bound each runtime's retained
  generations. Metadata and every hard-linked body count toward that budget.
  Temporary readers, pending publication and failed cleanup have separate charges.
  Admission or runtime failures bypass caching. Startup warms disposable hints
  asynchronously from bounded inventories; `inventory_interval`,
  `inventory_max_entries`, `inventory_max_bytes`, `warmup_max_partitions`,
  `warmup_max_candidates`, and `warmup_timeout` control its work.
  Periodic maintenance also publishes bounded logical usage reports. Set
  `root_max_bytes` to enable approximate volume pressure; `root_low_watermark`
  (0.8) leaves headroom and `usage_max_partitions` (128) bounds each scan.
  Missing/stale reports permit overshoot; these settings do not enforce a quota.
  Maintenance retires other incarnations after `inactivity_grace` seconds (3,600),
  then incrementally unlinks trash. `reclaim_max_partitions` (128) and
  `reclaim_max_entries` (256, minimum 32) bound each pass. Keep the partition limit
  above the number of live or within-grace writers so inactive entries can be
  reached. Heartbeats may be stale; eviction can cost cache hits on a live writer.
  Shared-mount qualification is still in progress.
  """
  @behaviour ImagePipe.Cache
  @behaviour ImagePipe.Cache.Input.Adapter

  alias ImagePipe.Cache.Entry

  alias ImagePipe.Cache.SharedFileSystem.{
    Generation,
    Locations,
    Lookup,
    Partition,
    Retainer,
    Runtime,
    Sink,
    Sources
  }

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  @schema NimbleOptions.new!(
            runtime: [type: :atom, required: true],
            timeout: [type: :pos_integer, default: 1_000],
            max_body_bytes: [type: {:or, [nil, :non_neg_integer]}, default: nil]
          )

  @doc "Returns the shared cache runtime supervisor specification."
  defdelegate child_spec(opts), to: Runtime

  @impl true
  def validate_options(opts), do: NimbleOptions.validate(opts, @schema)
  @impl true
  def validate_input_options(opts), do: validate_options(opts)

  @impl true
  def get(key, opts) do
    with {:ok, context} <- Runtime.context(opts[:runtime]),
         {:hit, reader} <- Lookup.output(context, key.hash, opts[:timeout]) do
      try do
        with {:ok, body} <- File.read(reader.path) do
          metadata = reader.metadata

          {:hit,
           %Entry{
             body: body,
             content_type: metadata.content_type,
             headers: metadata.headers,
             created_at: metadata.created_at,
             representation: metadata.representation,
             debug: metadata.debug,
             source_record: metadata.source_record
           }}
        end
      after
        Generation.release(context.pool, reader, opts[:timeout])
      end
    end
  end

  @impl true
  defdelegate open_sink(key, metadata, opts), to: Sink, as: :open
  @impl true
  defdelegate write_chunk(state, chunk, opts), to: Sink, as: :write
  @impl true
  defdelegate commit_sink(state, opts), to: Sink, as: :commit
  @impl true
  defdelegate abort_sink(state, opts), to: Sink, as: :abort

  @impl true
  def lookup_source(key, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]

    with {:ok, context} <- Runtime.context(opts[:runtime]) do
      case Sources.lookup(context.sources, key.hash, remaining(deadline)) do
        {:hit, _snapshot} = hit ->
          Retainer.request(context.retainer, :sources, key.hash, remaining(deadline))
          hit

        result ->
          result
      end
    end
  end

  @impl true
  def acquire_source(key, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]

    with {:ok, context} <- Runtime.context(opts[:runtime]),
         {:ok, lease, outcome} <- Sources.acquire(context.sources, key.hash, remaining(deadline)) do
      case Sources.lookup(context.sources, key.hash, remaining(deadline)) do
        :miss -> Lookup.source(context, key.hash, lease, remaining(deadline))
        _selected_or_unavailable -> :ok
      end

      {:ok, {context, lease}, outcome}
    end
  end

  @impl true
  def release_source({context, lease}, _opts), do: Sources.release(context.sources, lease)

  @impl true
  def publish_source(key, {context, lease}, record, path, cost, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:timeout]
    body_limit = min(opts[:max_body_bytes] || context.limits.body, context.limits.body)
    context = %{context | limits: %{context.limits | body: body_limit}}

    with {:ok, snapshot} <-
           Sources.publish(context.sources, key.hash, lease, record, remaining(deadline)) do
      publish_original(context, key.hash, record, path, cost, deadline)
      publish(context, :sources, key.hash, nil, record, deadline)
      {:ok, snapshot}
    end
  end

  defp publish_original(_context, _key, _record, nil, _cost, _deadline), do: :ok

  defp publish_original(context, key, record, path, cost, deadline) do
    original_key = Partition.original_key(key, record.byte_identity)

    publish(
      context,
      :originals,
      original_key,
      path,
      %{source_record: record, cost_us: cost},
      deadline
    )
  end

  defp publish(context, kind, key, path, metadata, deadline) do
    with {:ok, size} <- body_size(context, path, deadline),
         true <- size <= context.limits.body,
         {:ok, location} <-
           Retainer.publish(
             context.retainer,
             kind,
             key,
             path,
             metadata,
             size,
             remaining(deadline)
           ) do
      Locations.remember(context.locations, location, remaining(deadline))
    else
      false -> {:error, :body_too_large}
      error -> error
    end
  end

  defp body_size(_context, nil, _deadline), do: {:ok, 0}

  defp body_size(context, path, deadline) do
    case CacheIO.run(context.pool, {File, :stat, [path]}, 4_096, remaining(deadline)) do
      {:ok, {:ok, stat}} -> {:ok, stat.size}
      {:ok, error} -> error
      error -> error
    end
  end

  @impl true
  def invalidate_source(key, revision, opts) do
    with {:ok, context} <- Runtime.context(opts[:runtime]),
         do: Sources.invalidate(context.sources, key.hash, revision, opts[:timeout])
  end

  @impl true
  def open_input(key, record, opts) do
    with {:ok, context} <- Runtime.context(opts[:runtime]),
         {:hit, reader} <- Lookup.original(context, key.hash, record, opts[:timeout]) do
      {:ok, reader.path, {context.pool, reader}}
    end
  end

  @impl true
  def release_input({pool, reader}, opts), do: Generation.release(pool, reader, opts[:timeout])

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end

defmodule ImagePipe.Test.CacheObserver do
  @moduledoc false
  # A real file-system cache on a fresh temporary root, observed through its
  # telemetry. `observe/2` adds the cache to a config and forwards the cache
  # events of requests made with that config to the calling process:
  #
  #   * `{:cache_lookup, entry, hash}` and `{:source_order, :cache_lookup}` on
  #     each output-cache lookup. `entry` is `:response` for a processed
  #     response, or `:source_record` for the record of its original.
  #   * `{:cache_open_sink, hash, metadata}`, `{:cache_put, hash, body}` and
  #     `{:source_order, :cache_put}` when an entry is stored. `metadata` is the
  #     stored metadata map, read back from disk.
  #   * `{:cache_abort, hash}` when a streamed entry is abandoned or skipped
  #     before it is stored.
  #   * `{:cache_write_error, hash}` when storing an entry fails.
  #
  # Hashes are cache key hashes (`ImagePipe.Cache.Key.hash`). Handlers send to
  # the process that called `observe/2`, whichever process emits the event.
  # Observing twice on one prefix reports each write once, from the observer
  # whose root holds it. Lookups reach both.

  use Boundary, top_level?: true, check: [out: false]

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias ImagePipe.Cache.FileSystem.Store

  @doc """
  Returns `opts` with an output cache on a new temporary root, merged with
  `cache_opts`, and a telemetry prefix: the one `opts` already has, or a new
  private one. Cache events under that prefix go to the calling process.
  """
  def observe(opts, cache_opts \\ []) do
    root = Path.join(System.tmp_dir!(), "cache-observer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    cache = Keyword.merge([root: root], cache_opts)

    prefix =
      Keyword.get_lazy(opts, :telemetry_prefix, fn ->
        [__MODULE__, :"#{System.unique_integer([:positive])}"]
      end)

    attach(prefix, cache, self())

    opts
    |> Keyword.put(:cache, cache)
    |> Keyword.put(:telemetry_prefix, prefix)
  end

  @doc """
  Drains the response lookups (`{:cache_lookup, :response, hash}`) received so
  far, oldest first.
  """
  def lookup_hashes do
    receive do
      {:cache_lookup, :response, hash} -> [hash | lookup_hashes()]
    after
      0 -> []
    end
  end

  @doc "Reads the stored body for `hash` from the cache in `opts`, or `nil`."
  def stored_body(opts, hash) do
    case read(Keyword.fetch!(opts, :cache), hash) do
      {:ok, _metadata, body} -> body
      :error -> nil
    end
  end

  defp attach(prefix, cache, target) do
    id = {__MODULE__, make_ref()}

    events = [
      prefix ++ [:cache, :lookup, :start],
      prefix ++ [:cache, :write, :stop],
      prefix ++ [:cache, :stage]
    ]

    :ok = :telemetry.attach_many(id, events, &__MODULE__.handle/4, {cache, target})

    on_exit(fn ->
      :telemetry.detach(id)
      File.rm_rf(Keyword.fetch!(cache, :root))
    end)
  end

  @doc false
  def handle(event, _measurements, metadata, {cache, target}) do
    case {List.last(event), metadata} do
      {:start, %{cache_key: hash, entry: entry}} ->
        send(target, {:source_order, :cache_lookup})
        send(target, {:cache_lookup, entry, hash})

      {:stop, %{pool: :output, cache: :write, cache_key: hash}} ->
        # Tests that compare caches observe several on one prefix. A write
        # under another observer's root is that observer's to report.
        with {:ok, stored, body} <- read(cache, hash) do
          send(target, {:cache_open_sink, hash, stored})
          send(target, {:source_order, :cache_put})
          send(target, {:cache_put, hash, body})
        end

      {:stop, %{pool: :output, cache: :write_error, cache_key: hash}} ->
        send(target, {:cache_write_error, hash})

      {:stage, %{cache: status, cache_key: hash}}
      when status in [:stage_abandoned, :stage_skipped] ->
        send(target, {:cache_abort, hash})

      _other ->
        :ok
    end
  end

  defp read(cache, hash) do
    with {:ok, paths} <- Store.paths_from_hash(hash, cache),
         {:ok, metadata} <- Store.metadata(%ImagePipe.Cache.Key{hash: hash, data: []}, cache),
         {:ok, body} <- File.read(Path.join(paths.dir, metadata.body_filename)) do
      {:ok, metadata, body}
    else
      _missing -> :error
    end
  end
end

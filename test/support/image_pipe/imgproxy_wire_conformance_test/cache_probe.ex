defmodule ImgproxyWireConformanceTest.CacheProbe do
  @moduledoc false
  # Stateless by default (`get/2` returns the configured `:result`, or
  # `:miss`). Passing a `:store` option (an ETS table reference, owned by the
  # caller) makes lookups/commits stateful: `commit_sink/2` writes a real
  # `ImagePipe.Cache.Entry` keyed by the cache key hash, and a later `get/2`
  # against the same table returns it as a real `{:hit, entry}` — letting a
  # test exercise an actual miss-then-hit round trip through two real
  # requests without touching cache internals. `:store` is purely additive:
  # existing callers that never pass it see identical behavior to before.

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache]

  alias ImagePipe.Cache.Entry

  @behaviour ImagePipe.Cache

  @impl true
  def get(key, opts) do
    target = message_target()
    send(target, {:source_order, :cache_lookup})
    send(target, {:cache_lookup, key})

    case store_lookup(opts, key) do
      {:ok, entry} -> {:hit, entry}
      :error -> Keyword.get(opts, :result, :miss)
    end
  end

  @impl true
  def open_sink(key, metadata, opts) do
    target = message_target()
    send(target, {:cache_open_sink, key, metadata})
    {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}
  end

  @impl true
  def write_chunk(state, chunk, _opts) do
    {:ok, %{state | chunks: [chunk | state.chunks]}}
  end

  @impl true
  def commit_sink(state, opts) do
    target = message_target()
    body = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

    store_put(opts, state.key, state.metadata, body)

    send(target, {:source_order, :cache_put})
    send(target, {:cache_put, state.key, body})
    :ok
  end

  @impl true
  def abort_sink(_state, _opts), do: :ok

  defp store_lookup(opts, key) do
    case Keyword.fetch(opts, :store) do
      {:ok, table} ->
        case :ets.lookup(table, key.hash) do
          [{_hash, entry}] -> {:ok, entry}
          [] -> :error
        end

      :error ->
        :error
    end
  end

  defp store_put(opts, key, metadata, body) do
    case Keyword.fetch(opts, :store) do
      {:ok, table} ->
        entry = %Entry{
          body: body,
          content_type: metadata.content_type,
          headers: metadata.headers,
          created_at: metadata.created_at,
          debug: metadata.debug
        }

        :ets.insert(table, {key.hash, entry})

      :error ->
        :ok
    end
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end

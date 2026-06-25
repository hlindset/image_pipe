defmodule ImgproxyWireConformanceTest.CacheProbe do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache]

  @behaviour ImagePipe.Cache

  @impl true
  def get(key, opts) do
    target = message_target()
    send(target, {:source_order, :cache_lookup})
    send(target, {:cache_lookup, key})

    Keyword.get(opts, :result, :miss)
  end

  @impl true
  def open_sink(key, metadata, opts) do
    target = message_target()
    send(target, {:cache_open_sink, key, metadata})
    {:ok, %{key: key, chunks: [], opts: opts}}
  end

  @impl true
  def write_chunk(state, chunk, _opts) do
    {:ok, %{state | chunks: [chunk | state.chunks]}}
  end

  @impl true
  def commit_sink(state, _opts) do
    target = message_target()
    send(target, {:source_order, :cache_put})
    send(target, {:cache_put, state.key, Enum.reverse(state.chunks) |> IO.iodata_to_binary()})
    :ok
  end

  @impl true
  def abort_sink(_state, _opts), do: :ok

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end

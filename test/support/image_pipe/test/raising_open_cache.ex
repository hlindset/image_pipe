defmodule ImagePipe.Test.RaisingOpenCache do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePipe.Cache]

  @behaviour ImagePipe.Cache

  @impl true
  def get(_key, _opts), do: :miss

  @impl true
  def open_sink(_key, _metadata, opts) do
    send(Keyword.fetch!(opts, :test_pid), :cache_open_attempted)
    raise "adapter open crashed"
  end

  @impl true
  def write_chunk(state, _chunk, opts) do
    send(Keyword.fetch!(opts, :test_pid), :cache_write_attempted)
    {:ok, state}
  end

  @impl true
  def commit_sink(_state, opts) do
    send(Keyword.fetch!(opts, :test_pid), :cache_commit_attempted)
    :ok
  end

  @impl true
  def abort_sink(_state, _opts), do: :ok
end

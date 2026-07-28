defmodule ImagePipe.RequestSafetyTest.CacheProbe do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache]

  @behaviour ImagePipe.Cache

  def get(_key, _opts) do
    send(message_target(), :cache_lookup)
    :miss
  end

  def open_sink(_key, _metadata, _opts), do: {:ok, []}
  def write_chunk(chunks, chunk, _opts), do: {:ok, [chunk | chunks]}

  def commit_sink(_chunks, _opts) do
    send(message_target(), :cache_put)
    :ok
  end

  def abort_sink(_chunks, _opts), do: :ok

  # Cache writes run inside the delivery task, so a bare `self()` would deliver
  # the signal to a process the test never inspects — making every
  # `refute_received :cache_put` pass vacuously.
  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end

defmodule ImagePipe.SourceTest.StreamWithCleanup do
  @moduledoc false

  def stream(test_pid, chunks) do
    Stream.resource(
      fn -> chunks end,
      fn
        [] -> {:halt, []}
        [chunk | rest] -> {[chunk], rest}
      end,
      fn _state -> send(test_pid, :stream_closed) end
    )
  end

  def raising_stream do
    Stream.resource(
      fn -> :raise end,
      fn :raise -> raise "raw stream failure" end,
      fn _state -> :ok end
    )
  end
end

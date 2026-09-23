defmodule ImagePipe.Test.PacedSourceOrigin do
  @moduledoc false

  def child_spec(opts), do: %{Task.child_spec(fn -> serve(opts) end) | id: __MODULE__}

  defp serve(opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    observer = Keyword.fetch!(opts, :test_pid)
    send(observer, {:origin_ready, self(), "http://127.0.0.1:#{port}"})

    try do
      {:ok, socket} = :gen_tcp.accept(listener)

      try do
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        body = Keyword.fetch!(opts, :body)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: image/jpeg\r\ncache-control: public, max-age=600\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\n\r\n"
          ])

        <<prefix::binary-size(512 * 1024), tail::binary>> = body

        for <<chunk::binary-size(64 * 1024) <- prefix>> do
          :ok = :gen_tcp.send(socket, chunk)
          Process.send_after(self(), :next_chunk, 3)
          receive do: (:next_chunk -> :ok)
        end

        send(observer, {:origin_held, self()})

        receive do
          :continue -> :gen_tcp.send(socket, tail)
          :truncate -> :ok
        end
      after
        :gen_tcp.close(socket)
      end
    after
      :gen_tcp.close(listener)
    end
  end
end

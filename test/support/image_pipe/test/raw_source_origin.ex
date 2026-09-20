defmodule ImagePipe.Test.RawSourceOrigin do
  @moduledoc false

  def child_spec(opts) do
    %{Task.child_spec(fn -> serve(opts) end) | id: __MODULE__}
  end

  defp serve(opts) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    send(Keyword.fetch!(opts, :test_pid), {:origin_ready, self(), "http://127.0.0.1:#{port}"})

    try do
      {:ok, socket} = :gen_tcp.accept(listener)

      try do
        {:ok, _request} = :gen_tcp.recv(socket, 0)
        :ok = :gen_tcp.send(socket, Keyword.fetch!(opts, :response))
        finish(socket, Keyword.get(opts, :finish, :close))
      after
        :gen_tcp.close(socket)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp finish(_socket, :close), do: :ok
  defp finish(socket, :stall), do: :gen_tcp.recv(socket, 0, :infinity)

  defp finish(socket, :reset) do
    receive do
      :reset -> :inet.setopts(socket, linger: {true, 0})
    end
  end
end

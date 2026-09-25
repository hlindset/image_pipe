defmodule ImagePipe.Test.SharedCrashProbe do
  @moduledoc false
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Cache.SharedFileSystem
  alias ImagePipe.Cache.SharedFileSystem.{Generation, Runtime}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def acquire(root, local_root, location) do
    Application.put_env(:opentelemetry, :traces_exporter, :none)
    {:ok, _apps} = Application.ensure_all_started(:image_pipe)

    {:ok, runtime} =
      Supervisor.start_child(
        ImagePipe.Supervisor,
        {SharedFileSystem, name: __MODULE__, root: root, local_root: local_root}
      )

    {:ok, context} = Runtime.context(__MODULE__)
    caller = self()

    {:ok, _owner} =
      Task.Supervisor.start_child(ImagePipe.Cache.RefreshTasks, fn ->
        {:ok, reader} =
          Generation.acquire(context.pool, location, context.readers, context.limits, 5_000)

        send(caller, {:reader, reader.path, reader.metadata})

        receive do
          :release -> Generation.release(context.pool, reader, 5_000)
        end
      end)

    receive do
      {:reader, path, metadata} ->
        # Finish the helper's lifecycle before the parent test abruptly kills
        # this BEAM. The deployment cleanup then has no surviving helper I/O.
        :ok = Supervisor.terminate_child(runtime, CacheIO)
        {System.pid(), path, metadata}
    after
      10_000 -> {:error, :reader_timeout}
    end
  end
end

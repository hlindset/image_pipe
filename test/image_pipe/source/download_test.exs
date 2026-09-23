defmodule ImagePipe.Source.DownloadTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.Download

  setup do
    path = Path.join(System.tmp_dir!(), "download-#{System.unique_integer([:positive])}")
    File.write!(path, "prefix")
    on_exit(fn -> File.rm(path) end)
    tasks = start_supervised!(Task.Supervisor)
    download = start_supervised!({Download, owner: self(), path: path, available: 6})
    %{path: path, tasks: tasks, download: download}
  end

  test "replays staged bytes and waits for committed file growth", context do
    owner = self()

    reader =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        context.download
        |> Download.stream()
        |> Enum.map(fn chunk ->
          send(owner, {:read, chunk})
          chunk
        end)
        |> IO.iodata_to_binary()
      end)

    assert_receive {:read, "prefix"}
    File.write!(context.path, "tail", [:append])
    Download.advance(context.download, 10)
    assert_receive {:read, "tail"}
    Download.finish(context.download)
    assert Task.await(reader) == "prefixtail"
    assert context.download |> Download.stream() |> Enum.join() == "prefixtail"
  end

  test "closing a download terminates blocked readers", context do
    owner = self()

    reader =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        context.download
        |> Download.stream()
        |> Enum.each(fn bytes -> send(owner, {:read, bytes}) end)
      end)

    assert_receive {:read, "prefix"}
    monitor = Process.monitor(reader.pid)
    Download.close(context.download)
    assert_receive {:DOWN, ^monitor, :process, _, :shutdown}
    assert {:exit, :shutdown} = Task.yield(reader)
  end

  test "owner death terminates the worker and its readers", context do
    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        receive do
          :finish -> :ok
        end
      end)

    download =
      start_supervised!({Download, owner: owner.pid, path: context.path, available: 6},
        id: :owned
      )

    observer = self()

    worker =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        send(observer, :worker_ready)

        receive do
          :finish -> :ok
        end
      end)

    Download.watch(download, worker.pid)
    assert_receive :worker_ready
    monitor = Process.monitor(worker.pid)
    download_monitor = Process.monitor(download)
    send(owner.pid, :finish)
    Task.await(owner)
    assert_receive {:DOWN, ^monitor, :process, _, :shutdown}
    assert_receive {:DOWN, ^download_monitor, :process, _, :normal}
    assert {:exit, :shutdown} = Task.yield(worker)
  end
end

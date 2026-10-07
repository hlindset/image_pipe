defmodule ImagePipe.Source.DownloadTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  property "generated writes replay exactly during growth and after completion", context do
    check all boundary <- member_of([65_535, 65_536, 65_537, 1_048_575, 1_048_576, 1_048_577]),
              tail <- list_of(binary(max_length: 4_096), max_length: 8),
              max_runs: 30 do
      id = make_ref()
      File.write!(context.path, "prefix")

      download =
        start_supervised!({Download, owner: self(), path: context.path, available: 6}, id: id)

      owner = self()

      reader =
        Task.Supervisor.async_nolink(context.tasks, fn ->
          download
          |> Download.stream()
          |> Stream.transform(0, fn bytes, offset ->
            offset = offset + byte_size(bytes)
            send(owner, {id, :read, offset})
            {[bytes], offset}
          end)
          |> Enum.to_list()
          |> IO.iodata_to_binary()
        end)

      assert_receive {^id, :read, 6}
      pattern = "boundary-#{boundary}|"
      large = :binary.copy(pattern, div(boundary, byte_size(pattern)) + 1)
      chunks = [binary_part(large, 0, boundary), "" | tail]

      Enum.reduce(chunks, 6, fn bytes, offset ->
        File.write!(context.path, bytes, [:append])
        next = offset + byte_size(bytes)
        :ok = Download.advance(download, next)
        if next > offset, do: await_offset(id, next)
        next
      end)

      :ok = Download.finish(download)
      expected = IO.iodata_to_binary(["prefix" | chunks])
      assert Task.await(reader) == expected
      assert download |> Download.stream() |> Enum.to_list() |> IO.iodata_to_binary() == expected
      stop_supervised!(id)
    end
  end

  defp await_offset(id, expected) do
    receive do
      {^id, :read, ^expected} -> :ok
      {^id, :read, offset} when offset < expected -> await_offset(id, expected)
    after
      2_000 -> flunk("reader did not reach #{expected}")
    end
  end

  test "a truncated published chunk is rejected before any bytes are yielded", context do
    File.write!(context.path, "pre")

    assert_raise ImagePipe.Source.StreamError, ~r/invalid_body/, fn ->
      context.download |> Download.stream() |> Enum.take(1)
    end
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

    worker =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        receive do
          {:sync, from} -> send(from, :synced)
        end

        receive do
          :finish -> :ok
        end
      end)

    Download.watch(download, worker.pid)

    # A monitor is a signal, ordered only against later signals from the same
    # sender. Round-trip each process after monitoring it so both monitors are
    # in place before the owner's exit can reach the download.
    monitor = Process.monitor(worker.pid)
    send(worker.pid, {:sync, self()})
    assert_receive :synced
    download_monitor = Process.monitor(download)
    _ = :sys.get_state(download)

    send(owner.pid, :finish)
    Task.await(owner)
    assert_receive {:DOWN, ^monitor, :process, _, :shutdown}
    assert_receive {:DOWN, ^download_monitor, :process, _, :normal}
    assert {:exit, :shutdown} = Task.yield(worker)
  end
end

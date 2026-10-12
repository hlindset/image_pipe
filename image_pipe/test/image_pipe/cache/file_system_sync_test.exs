defmodule ImagePipe.Cache.FileSystemSyncTest do
  # Call tracing is VM-wide, so this module doesn't run concurrently.
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key

  setup do
    root =
      Path.join(System.tmp_dir!(), "image_pipe_fs_sync_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, opts} = FileSystem.validate_options(root: root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    :ok = Admission.await_scan(admission)
    {:ok, opts: opts, admission: admission}
  end

  test "a committed body is synced to disk before it is renamed into place", %{
    opts: opts,
    admission: admission
  } do
    key = %Key{hash: String.duplicate("e", 64), data: []}

    metadata = %Metadata{
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z],
      output_format: :webp
    }

    {:ok, state} = FileSystem.open_sink(key, metadata, opts)
    {:ok, state} = FileSystem.write_chunk(state, "encoded image", opts)

    # The request syncs the body and Admission renames it, so both are traced
    # and the calls are ordered by their timestamps.
    tracer = spawn_link(fn -> collect([]) end)
    traced = [self(), admission]

    for pid <- traced,
        do: :erlang.trace(pid, true, [:call, :strict_monotonic_timestamp, {:tracer, tracer}])

    :erlang.trace_pattern({:file, :datasync, 1}, true, [])
    :erlang.trace_pattern({:file, :rename, 2}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({:file, :datasync, 1}, false, [])
      :erlang.trace_pattern({:file, :rename, 2}, false, [])
    end)

    assert FileSystem.commit_sink(state, opts) == :ok

    for pid <- traced do
      :erlang.trace(pid, false, [:call])
      delivered = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, _pid, ^delivered}
    end

    send(tracer, {:calls, self()})
    assert_receive {:calls, calls}

    assert [:datasync, {:rename, body_path} | _meta] = calls
    assert String.ends_with?(body_path, ".body")
    assert {:hit, entry} = FileSystem.get(key, opts)
    assert entry.body == "encoded image"
  end

  defp collect(calls) do
    receive do
      {:trace_ts, _pid, :call, {:file, :datasync, [_io]}, ts} ->
        collect([{ts, :datasync} | calls])

      {:trace_ts, _pid, :call, {:file, :rename, [_from, to]}, ts} ->
        collect([{ts, {:rename, to}} | calls])

      {:calls, pid} ->
        send(pid, {:calls, calls |> Enum.sort() |> Enum.map(&elem(&1, 1))})
    end
  end
end

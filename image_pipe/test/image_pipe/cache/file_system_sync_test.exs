defmodule ImagePipe.Cache.FileSystemSyncTest do
  # Call tracing is VM-wide, so this module doesn't run concurrently.
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  setup do
    root =
      Path.join(System.tmp_dir!(), "image_pipe_fs_sync_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "a committed body is synced to disk before it is renamed into place", %{root: root} do
    key = %Key{hash: String.duplicate("e", 64), data: []}

    metadata = %Metadata{
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z],
      output_format: :webp
    }

    {:ok, state} = FileSystem.open_sink(key, metadata, root: root)
    {:ok, state} = FileSystem.write_chunk(state, "encoded image", root: root)

    tracer = spawn_link(fn -> collect([]) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({:file, :datasync, 1}, true, [])
    :erlang.trace_pattern({:file, :rename, 2}, true, [])

    on_exit(fn ->
      :erlang.trace_pattern({:file, :datasync, 1}, false, [])
      :erlang.trace_pattern({:file, :rename, 2}, false, [])
    end)

    assert FileSystem.commit_sink(state, root: root) == :ok
    :erlang.trace(self(), false, [:call])
    delivered = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^delivered}
    send(tracer, {:calls, self()})
    assert_receive {:calls, calls}

    assert [:datasync, {:rename, body_path} | _meta] = calls
    assert String.ends_with?(body_path, ".body")
    assert {:hit, entry} = FileSystem.get(key, root: root)
    assert entry.body == "encoded image"
  end

  defp collect(calls) do
    receive do
      {:trace, _pid, :call, {:file, :datasync, [_io]}} -> collect([:datasync | calls])
      {:trace, _pid, :call, {:file, :rename, [_from, to]}} -> collect([{:rename, to} | calls])
      {:calls, pid} -> send(pid, {:calls, Enum.reverse(calls)})
    end
  end
end

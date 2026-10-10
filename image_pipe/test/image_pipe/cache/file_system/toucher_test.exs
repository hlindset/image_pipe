defmodule ImagePipe.Cache.FileSystem.ToucherTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Toucher
  alias ImagePipe.Cache.Key

  @unread System.os_time(:second) - 86_400

  setup do
    root =
      Path.join(System.tmp_dir!(), "image_pipe_toucher_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    {key, paths} = entry!(root)
    File.touch!(paths.meta_path, @unread)
    {:ok, root: root, key: key, paths: paths}
  end

  test "a read moves the metadata mtime at the next touch", %{root: root, key: key, paths: paths} do
    pid = start_supervised!(Toucher.child_spec(root: root))

    assert {:hit, _entry} = FileSystem.get(key, root: root)
    assert mtime(paths) == @unread

    send(pid, :touch)
    _ = :sys.get_state(pid)
    assert mtime(paths) > @unread
  end

  test "an entry removed before the touch stays removed", %{root: root, key: key, paths: paths} do
    pid = start_supervised!(Toucher.child_spec(root: root))
    assert {:hit, _entry} = FileSystem.get(key, root: root)
    File.rm!(paths.meta_path)

    send(pid, :touch)
    _ = :sys.get_state(pid)
    refute File.exists?(paths.meta_path)
  end

  test "stopping the toucher touches the pending reads", %{root: root, key: key, paths: paths} do
    start_supervised!(Toucher.child_spec(root: root))
    assert {:hit, _entry} = FileSystem.get(key, root: root)

    stop_supervised!({Toucher, root, ""})
    assert mtime(paths) > @unread
  end

  test "a second toucher on the same cache takes over when the first stops", %{
    root: root,
    key: key,
    paths: paths
  } do
    start_supervised!(Toucher.child_spec(root: root))
    second = start_supervised!(%{Toucher.child_spec(root: root) | id: :second})
    _ = :sys.get_state(second)

    stop_supervised!({Toucher, root, ""})
    _ = :sys.get_state(second)

    assert {:hit, _entry} = FileSystem.get(key, root: root)
    send(second, :touch)
    _ = :sys.get_state(second)
    assert mtime(paths) > @unread
  end

  test "caches that share a root but not a prefix record their reads apart", %{root: root} do
    {key, paths} = entry!(root, "images")
    File.touch!(paths.meta_path, @unread)
    other = start_supervised!(Toucher.child_spec(root: root))
    prefixed = start_supervised!(Toucher.child_spec(root: root, path_prefix: "images"))

    assert {:hit, _entry} = FileSystem.get(key, root: root, path_prefix: "images")

    send(other, :touch)
    _ = :sys.get_state(other)
    assert mtime(paths) == @unread

    send(prefixed, :touch)
    _ = :sys.get_state(prefixed)
    assert mtime(paths) > @unread
  end

  test "reads are saved at least four times within max_age", %{root: root} do
    hourly = start_supervised!(Toucher.child_spec(root: root, max_age: 7 * 86_400))
    short = start_supervised!(Toucher.child_spec(root: root, path_prefix: "s", max_age: 600))

    assert :sys.get_state(hourly).interval_ms == 3_600_000
    assert :sys.get_state(short).interval_ms == 150_000
  end

  test "reads without a running toucher still hit", %{root: root, key: key, paths: paths} do
    assert {:hit, _entry} = FileSystem.get(key, root: root)
    assert mtime(paths) == @unread
  end

  defp entry!(root, path_prefix \\ "") do
    key = %Key{hash: String.duplicate("a", 64), data: [entry: :a]}
    opts = [root: root, path_prefix: path_prefix]

    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-10-09 10:00:00Z],
        output_format: :webp
      )

    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, "body", opts)
    :ok = FileSystem.commit_sink(sink, opts)
    {:ok, paths} = FileSystem.paths(key, opts)
    {key, paths}
  end

  defp mtime(paths) do
    {:ok, %{mtime: mtime}} = File.stat(paths.meta_path, time: :posix)
    mtime
  end
end

defmodule ImagePipe.Cache.FileSystem.SweepTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Sweep

  @hash String.duplicate("a", 64)
  @other String.duplicate("b", 64)
  @sha String.duplicate("c", 64)
  @old System.os_time(:second) - 7_200

  setup do
    root = Path.join(System.tmp_dir!(), "image_pipe_sweep_#{System.unique_integer([:positive])}")
    dir = Path.join([root, "aa", "aa"])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, dir: dir}
  end

  defp write!(dir, name, mtime \\ nil) do
    path = Path.join(dir, name)
    File.write!(path, "bytes")
    if mtime, do: File.touch!(path, mtime)
    path
  end

  defp pin_name(ms), do: ".image-pipe-pin-#{ms}-Ab_c-dE.tmp"

  test "removes expired temps and untracked bodies and keeps everything live", %{
    root: root,
    dir: dir
  } do
    tracked = write!(dir, "#{@hash}.#{@sha}.body", @old)
    write!(dir, "#{@hash}.meta")
    untracked = write!(dir, "#{@other}.#{@sha}.body", @old)
    fresh_untracked = write!(dir, "#{@other}.#{String.duplicate("d", 64)}.body")

    expired_pin = write!(dir, pin_name(System.os_time(:millisecond) - 7_200_000))
    fresh_pin = Path.join(dir, pin_name(System.os_time(:millisecond)))
    File.ln!(tracked, fresh_pin)
    legacy_pin = write!(dir, ".image-pipe-Ab_c-dE.tmp", @old)

    expired_temp = write!(dir, ".#{@hash}.Ab_c-dE.tmp", @old)
    fresh_temp = write!(dir, ".#{@other}.Ab_c-dE.tmp")
    unrelated = write!(dir, "notes.txt", @old)

    assert %{pins: 1, temps: 1, bodies: 1, bytes: 15} = Sweep.sweep_root(root)

    refute File.exists?(expired_pin)
    refute File.exists?(expired_temp)
    refute File.exists?(untracked)

    for path <- [tracked, fresh_untracked, fresh_pin, legacy_pin, fresh_temp, unrelated],
        do: assert(File.exists?(path))
  end

  test "an undecodable meta still keeps its body", %{root: root, dir: dir} do
    body = write!(dir, "#{@hash}.#{@sha}.body", @old)
    File.write!(Path.join(dir, "#{@hash}.meta"), "not a term")

    assert %{bodies: 0} = Sweep.sweep_root(root)
    assert File.exists?(body)
  end

  test "removes an old body whose key's meta names another body", %{root: root} do
    key = %ImagePipe.Cache.Key{hash: @hash, data: [schema_version: 1]}
    opts = [root: root]

    metadata =
      struct!(ImagePipe.Cache.Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-10-09 10:00:00Z],
        output_format: :webp
      )

    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, "current body", opts)
    FileSystem.commit_sink(sink, opts)

    {:ok, paths} = FileSystem.paths(key, opts)
    [current] = Path.wildcard(Path.join(paths.dir, "*.body"))
    File.touch!(current, @old)
    stranded = write!(paths.dir, "#{@hash}.#{String.duplicate("e", 64)}.body", @old)
    fresh = write!(paths.dir, "#{@hash}.#{String.duplicate("f", 64)}.body")

    assert %{bodies: 1} = Sweep.sweep_root(root)
    refute File.exists?(stranded)
    assert File.exists?(current)
    assert File.exists?(fresh)
    assert {:hit, _entry} = FileSystem.get(key, opts)
  end

  test "skips directories that aren't cache partitions", %{root: root} do
    state = Path.join(root, ".cache_state")
    File.mkdir_p!(state)
    path = write!(state, ".#{@hash}.Ab_c-dE.tmp", @old)

    assert %{temps: 0} = Sweep.sweep_root(root)
    assert File.exists?(path)
  end

  test "a missing root is an empty sweep" do
    assert %{pins: 0, temps: 0, bodies: 0, bytes: 0} =
             Sweep.sweep_root(Path.join(System.tmp_dir!(), "missing-#{System.unique_integer()}"))
  end

  test "removes expired staged originals and keeps fresh ones", %{dir: dir} do
    expired = write!(dir, ".image-pipe-Ab_c-dE.tmp", @old)
    fresh = write!(dir, ".image-pipe-Fg_h-iJ.tmp")
    other = write!(dir, "other.tmp", @old)

    assert %{staged: 1, bytes: 5} = Sweep.sweep_staged(dir)
    refute File.exists?(expired)
    assert File.exists?(fresh)
    assert File.exists?(other)
  end
end

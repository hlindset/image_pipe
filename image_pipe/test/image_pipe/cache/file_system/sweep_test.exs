defmodule ImagePipe.Cache.FileSystem.SweepTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.FileSystem.Sweep
  alias ImagePipe.Test.Caches

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

  # A body named for its 5-byte content ("bytes") and no cost.
  defp body_name(hash, sha), do: "#{hash}.#{sha}.5.0.body"

  test "removes expired temps and untracked bodies and keeps everything live", %{
    root: root,
    dir: dir
  } do
    tracked = write!(dir, body_name(@hash, @sha), @old)
    write!(dir, "#{@hash}.meta")
    untracked = write!(dir, body_name(@other, @sha), @old)
    fresh_untracked = write!(dir, body_name(@other, String.duplicate("d", 64)))

    staged_name = write!(dir, ".image-pipe-Ab_c-dE.tmp", @old)

    expired_temp = write!(dir, ".#{@hash}.Ab_c-dE.tmp", @old)
    fresh_temp = write!(dir, ".#{@other}.Ab_c-dE.tmp")
    unrelated = write!(dir, "notes.txt", @old)

    assert %{temps: 1, bodies: 1, bytes: 10} = Sweep.sweep_root(root)

    refute File.exists?(expired_temp)
    refute File.exists?(untracked)

    for path <- [tracked, fresh_untracked, staged_name, fresh_temp, unrelated],
        do: assert(File.exists?(path))
  end

  test "a new undecodable meta still keeps its body", %{root: root, dir: dir} do
    body = write!(dir, body_name(@hash, @sha), @old)
    File.write!(Path.join(dir, "#{@hash}.meta"), "not a term")

    assert %{bodies: 0} = Sweep.sweep_root(root)
    assert File.exists?(body)
  end

  test "removes an old body whose key's meta names another body", %{root: root} do
    key = %ImagePipe.Cache.Key{hash: @hash, data: [schema_version: 1]}
    opts = [root: root, max_size_bytes: 1_000_000]

    metadata =
      struct!(ImagePipe.Cache.Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-10-09 10:00:00Z],
        output_format: :webp
      )

    paths = Caches.write!(opts, key, metadata, "current body")
    [current] = Path.wildcard(Path.join(paths.dir, "*.body"))
    File.touch!(current, @old)
    stranded = write!(paths.dir, body_name(@hash, String.duplicate("e", 64)), @old)
    fresh = write!(paths.dir, body_name(@hash, String.duplicate("f", 64)))

    assert %{bodies: 1} = Sweep.sweep_root(root)
    refute File.exists?(stranded)
    assert File.exists?(current)
    assert File.exists?(fresh)
    assert {:hit, _entry} = FileSystem.get(key, opts)
  end

  # Commits and evictions never leave this. A key's only body is taken as the
  # one its meta names, as Admission's count does, and isn't read to check.
  test "keeps a key's only body beside its meta without reading the meta", %{root: root} do
    {_key, paths} = entry!(root, "5")
    [body] = Path.wildcard(Path.join(paths.dir, "*.body"))
    lone = Path.join(paths.dir, body_name(String.duplicate("5", 64), String.duplicate("e", 64)))
    File.rename!(body, lone)
    age!(paths, @old)

    assert %{bodies: 0} = Sweep.sweep_root(root)
    assert File.exists?(lone)
  end

  test "removes old metadata the cache can't read, with its body", %{root: root} do
    {readable_key, readable} = entry!(root, "1")
    {_key, unreadable} = entry!(root, "2")
    File.write!(unreadable.meta_path, "not a term")
    unmark!(root)
    age!(readable, @old)
    age!(unreadable, @old)

    assert %{unreadable: 1, bodies: 1} = Sweep.sweep_root(root)

    refute File.exists?(unreadable.meta_path)
    assert {:hit, _entry} = FileSystem.get(readable_key, root: root, max_size_bytes: 1_000_000)
  end

  test "removes an old unreadable meta that names no key without reporting it", %{dir: dir} do
    path = write!(dir, "notes.meta", @old)

    assert %{unreadable: 1, removed: removed} = Sweep.sweep_root(Path.dirname(Path.dirname(dir)))

    refute File.exists?(path)
    assert removed == []
  end

  describe "metadata version marker" do
    setup %{root: root} do
      {_key, paths} = entry!(root, "6")
      File.write!(paths.meta_path, "not a term")
      age!(paths, @old)
      unmark!(root)
      %{meta_path: paths.meta_path, marker: Path.join(root, ".metadata-version")}
    end

    test "a cache swept at this version skips the decode check", ctx do
      File.write!(ctx.marker, current_version())

      assert %{unreadable: 0} = Sweep.sweep_root(ctx.root)
      assert File.exists?(ctx.meta_path)
    end

    test "a cache without a marker is checked once, then marked", ctx do
      assert %{unreadable: 1} = Sweep.sweep_root(ctx.root)
      refute File.exists?(ctx.meta_path)
      assert File.read!(ctx.marker) == current_version()
    end

    test "metadata too new to remove keeps the cache unmarked until it goes", ctx do
      File.touch!(ctx.meta_path)

      assert %{unreadable: 0} = Sweep.sweep_root(ctx.root)
      assert File.exists?(ctx.meta_path)
      refute File.exists?(ctx.marker)

      File.touch!(ctx.meta_path, @old)
      assert %{unreadable: 1} = Sweep.sweep_root(ctx.root)
      assert File.read!(ctx.marker) == current_version()
    end

    test "a cache swept at another version is checked again", ctx do
      File.write!(ctx.marker, "1")

      assert %{unreadable: 1} = Sweep.sweep_root(ctx.root)
      refute File.exists?(ctx.meta_path)
      assert File.read!(ctx.marker) == current_version()
    end
  end

  defp current_version, do: Integer.to_string(Store.metadata_version())

  # Writing an entry starts a cache on the root, whose startup sweep marks it
  # as checked. Metadata that stops decoding afterwards models a cache last
  # swept at another version.
  defp unmark!(root), do: File.rm!(Path.join(root, ".metadata-version"))

  test "keeps metadata it can't read for now, such as on a permission error", %{root: root} do
    {key, paths} = entry!(root, "4")
    age!(paths, @old)
    File.chmod!(paths.meta_path, 0o000)
    on_exit(fn -> File.chmod(paths.meta_path, 0o644) end)

    assert %{unreadable: 0, bodies: 0} = Sweep.sweep_root(root)

    File.chmod!(paths.meta_path, 0o644)
    assert {:hit, _entry} = FileSystem.get(key, root: root, max_size_bytes: 1_000_000)
  end

  test "removes an entry whose body is named by digest alone", %{root: root} do
    {_key, paths} = entry!(root, "3")
    metadata = paths.meta_path |> File.read!() |> :erlang.binary_to_term()
    old_name = "#{String.duplicate("3", 64)}.#{metadata.body_sha256}.body"
    File.rename!(Path.join(paths.dir, metadata.body_filename), Path.join(paths.dir, old_name))
    File.write!(paths.meta_path, :erlang.term_to_binary(%{metadata | body_filename: old_name}))
    age!(paths, @old)
    unmark!(root)

    assert %{unreadable: 1, bodies: 1} = Sweep.sweep_root(root)
    assert File.ls!(paths.dir) == []
  end

  defp entry!(root, digit) do
    key = %ImagePipe.Cache.Key{hash: String.duplicate(digit, 64), data: [entry: digit]}

    metadata =
      struct!(ImagePipe.Cache.Entry.Metadata,
        content_type: "image/webp",
        headers: [],
        created_at: ~U[2026-10-09 10:00:00Z],
        output_format: :webp
      )

    {key, Caches.write!([root: root], key, metadata, "body " <> digit)}
  end

  defp age!(paths, mtime) do
    for path <- Path.wildcard(Path.join(paths.dir, "*")), do: File.touch!(path, mtime)
  end

  test "skips directories that aren't cache partitions", %{root: root} do
    state = Path.join(root, ".cache_state")
    File.mkdir_p!(state)
    path = write!(state, ".#{@hash}.Ab_c-dE.tmp", @old)

    assert %{temps: 0} = Sweep.sweep_root(root)
    assert File.exists?(path)
  end

  test "a missing root is an empty sweep" do
    assert %{temps: 0, bodies: 0, unreadable: 0, bytes: 0} =
             Sweep.sweep_root(Path.join(System.tmp_dir!(), "missing-#{System.unique_integer()}"))
  end
end

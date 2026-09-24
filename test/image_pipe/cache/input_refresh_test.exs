defmodule ImagePipe.Cache.InputRefreshTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source
  alias ImagePipe.Source.Record

  setup do
    root = Path.join(System.tmp_dir!(), "input_refresh_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = [root: root, node_id: "test", max_size_bytes: 100_000, window_ratio: 1.0]
    start_supervised!(FileSystem.child_spec(pool))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    File.mkdir_p!(root)
    path = Path.join(root, "source")
    File.write!(path, "image")
    key = %Key{hash: String.duplicate("a", 64), data: []}
    config = [input_cache: {FileSystem, pool}]
    original = record("image", 1000)
    snapshot = publish(key, path, original, config)
    %{pool: pool, key: key, config: config, original: original, snapshot: snapshot, path: path}
  end

  test "revalidation updates evidence without replacing original bytes or cost", ctx do
    {:ok, before} = Store.metadata(ctx.key, ctx.pool)
    refreshed = record("image", 1060)
    snapshot = publish(ctx.key, nil, refreshed, ctx.config)
    assert Input.lookup(ctx.key, ctx.config) == snapshot
    assert snapshot.record == refreshed
    refute snapshot.revision == ctx.snapshot.revision
    assert Store.metadata(ctx.key, ctx.pool) == {:ok, before}
    assert {:ok, path, handle} = Input.open(ctx.key, refreshed, ctx.config)
    assert File.read!(path) == "image"
    assert :ok = Input.release(handle)
    refute File.exists?(path)
  end

  test "a delayed invalidation cannot remove a newer source revision", ctx do
    replacement = record("new image", 1060)
    File.write!(ctx.path, "new image")
    snapshot = publish(ctx.key, ctx.path, replacement, ctx.config)
    assert :ok = Input.invalidate(ctx.key, ctx.snapshot.revision, ctx.config)
    assert Input.lookup(ctx.key, ctx.config) == snapshot
    assert {:ok, path, handle} = Input.open(ctx.key, replacement, ctx.config)
    assert File.read!(path) == "new image"
    Input.release(handle)
  end

  test "invalidation leaves a marker and an active original stays readable", ctx do
    assert {:ok, path, handle} = Input.open(ctx.key, ctx.original, ctx.config)
    assert :ok = Input.invalidate(ctx.key, ctx.snapshot.revision, ctx.config)
    assert %{record: nil} = Input.lookup(ctx.key, ctx.config)
    assert Input.open(ctx.key, ctx.original, ctx.config) == :miss
    assert File.read!(path) == "image"
    Input.release(handle)
    refute File.exists?(path)
  end

  test "original eviction retains authoritative source evidence", ctx do
    assert :ok = Store.delete(ctx.key, ctx.pool)
    assert Input.open(ctx.key, ctx.original, ctx.config) == :miss
    assert Input.lookup(ctx.key, ctx.config) == ctx.snapshot
  end

  test "freshness and body selection stay separate when only a new record is stored", ctx do
    next = record("different", 1060)
    snapshot = publish(ctx.key, nil, next, ctx.config)
    assert Input.lookup(ctx.key, ctx.config) == snapshot
    assert Input.open(ctx.key, next, ctx.config) == :miss
  end

  defp publish(key, path, record, config) do
    {:ok, lease} = Input.acquire(key, config)

    try do
      assert {:ok, snapshot} = Input.publish(key, lease, record, path, 25, config)
      snapshot
    after
      Input.release_source(lease)
    end
  end

  defp record(bytes, now) do
    {:ok, source, _config} = Source.from_input({:binary, bytes}, sources: %{})
    Record.new(source, :crypto.hash(:sha256, bytes), nil, now)
  end
end

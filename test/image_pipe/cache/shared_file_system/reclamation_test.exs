defmodule ImagePipe.Cache.SharedFileSystem.ReclamationTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.{Directory, Partition, Reclamation}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_reclaim_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    {:ok, {:ok, owner}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    {:ok, {:ok, other}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    %{root: root, pool: pool, owner: owner, other: other}
  end

  test "inactive retirement permits recovery without recreating the retired incarnation", ctx do
    File.touch!(Path.join(ctx.owner.path, "heartbeat"), 100)
    File.touch!(Path.join(ctx.other.path, "heartbeat"), 100)
    assert {:ok, %{retired: 1, errors: 0, scan: :complete}} = retire(ctx, 200)
    assert File.dir?(ctx.owner.path)
    refute File.exists?(ctx.other.path)
    assert {:error, :enoent} = Partition.heartbeat(ctx.other)
    assert {:ok, replacement} = Partition.recover(ctx.other)
    refute replacement.id == ctx.other.id
    assert {:ok, %{errors: 0}} = sweep(ctx)
    assert File.dir?(replacement.path)
    assert File.ls!(Path.join(ctx.root, "trash")) == []
  end

  test "fresh or missing startup heartbeats receive the full grace period", ctx do
    File.touch!(Path.join(ctx.other.path, "heartbeat"), 150)
    assert {:ok, %{retired: 0}} = retire(ctx, 200)
    File.rm!(Path.join(ctx.other.path, "heartbeat"))
    File.touch!(ctx.other.path, 150)
    assert {:ok, %{retired: 0}} = retire(ctx, 200)
    assert {:ok, %{retired: 1}} = retire(ctx, 211)
  end

  test "retirement and trash cleanup preserve an adopted hard link", ctx do
    old = Path.join(ctx.other.path, "body")
    retained = Path.join(ctx.owner.path, "adopted")
    File.write!(old, "retained bytes")
    File.ln!(old, retained)
    File.touch!(Path.join(ctx.other.path, "heartbeat"), 100)
    assert {:ok, %{retired: 1}} = retire(ctx, 200)
    assert {:ok, %{errors: 0}} = sweep(ctx)
    assert File.read!(retained) == "retained bytes"
  end

  test "failed cleanup remains retryable without touching active staging", ctx do
    active = Path.join(ctx.owner.path, "staging/active")
    File.mkdir!(active)
    File.write!(Path.join(active, "body"), "in progress")
    {:ok, retired} = Partition.retire(ctx.other)
    blocked = Path.join(retired, "blocked")
    deepest = Path.join([blocked | List.duplicate("nested", 9)])
    File.mkdir_p!(deepest)
    File.write!(Path.join(deepest, "body"), "pending")
    assert {:ok, %{errors: errors}} = sweep(ctx)
    assert errors > 0
    assert File.exists?(retired)
    File.rm_rf!(blocked)

    assert {:ok, %{errors: 0}} = sweep(ctx)
    refute File.exists?(retired)
    assert File.read!(Path.join(active, "body")) == "in progress"
  end

  defp retire(ctx, now),
    do: run(ctx, {Reclamation, :retire, [ctx.root, ctx.owner.id, now, 60, 16]})

  defp sweep(ctx), do: run(ctx, {Directory, :sweep, [Path.join(ctx.root, "trash"), 64]})

  defp run(ctx, operation) do
    {:ok, result} = CacheIO.run(ctx.pool, operation, 1_048_576, 1_000)
    result
  end
end

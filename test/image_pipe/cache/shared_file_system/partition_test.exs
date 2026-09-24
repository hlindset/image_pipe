defmodule ImagePipe.Cache.SharedFileSystem.PartitionTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.Partition

  setup do
    root = Path.join(System.tmp_dir!(), "shared_partition_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    pool =
      start_supervised!({CacheIO, max_operations: 2, max_bytes: 1_000_000}) |> CacheIO.client()

    %{pool: pool, root: root}
  end

  test "retirement is retryable and a resumed writer gets a new identity", ctx do
    assert {:ok, first} = call(ctx, :create, [ctx.root])
    assert :ok = call(ctx, :heartbeat, [first])
    assert {:ok, retired} = call(ctx, :retire, [first])
    assert {:ok, ^retired} = call(ctx, :retire, [first])
    assert File.dir?(retired)
    assert {:error, :enoent} = call(ctx, :heartbeat, [first])
    assert {:ok, replacement} = call(ctx, :recover, [first])
    refute replacement.id == first.id
    refute File.exists?(first.path)
    assert File.dir?(replacement.path)
  end

  test "staging never recreates a retired ancestor", ctx do
    {:ok, partition} = call(ctx, :create, [ctx.root])
    {:ok, _retired} = call(ctx, :retire, [partition])
    key = String.duplicate("a", 64)
    plan = Partition.plan(partition, :outputs, key)
    assert {:error, :enoent} = call(ctx, :stage, [plan])
    refute File.exists?(partition.path)
  end

  test "concurrent generations have distinct staging and destination names", ctx do
    {:ok, partition} = call(ctx, :create, [ctx.root])
    key = String.duplicate("a", 64)
    first = Partition.plan(partition, :outputs, key)
    second = Partition.plan(partition, :outputs, key)
    refute File.exists?(first.stage)
    assert :ok = call(ctx, :stage, [first])
    assert :ok = call(ctx, :stage, [second])
    refute first.stage == second.stage
    refute first.destination == second.destination
    assert File.dir?(first.stage)
    refute File.exists?(first.destination)
    assert {:ok, ^partition} = call(ctx, :recover, [partition])
  end

  defp call(ctx, function, args) do
    {:ok, result} = CacheIO.run(ctx.pool, {Partition, function, args}, 0, 1_000)
    result
  end
end

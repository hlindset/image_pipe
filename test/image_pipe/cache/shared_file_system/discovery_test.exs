defmodule ImagePipe.Cache.SharedFileSystem.DiscoveryTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.{Discovery, Generation, Partition}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup do
    root = Path.join(System.tmp_dir!(), "shared_discovery_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    {:ok, {:ok, first}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    {:ok, {:ok, second}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    source = Path.join(root, "source")
    File.write!(source, "encoded image")
    key = String.duplicate("a", 64)
    %{pool: pool, root: root, source: source, key: key, first: first, second: second}
  end

  test "discovers exact-key generations across independent writers", ctx do
    first = publish(ctx, ctx.first, ctx.key)
    second = publish(ctx, ctx.second, ctx.key)
    _other_key = publish(ctx, ctx.first, String.duplicate("b", 64))
    assert {:ok, partitions, :complete} = call(ctx, :partitions, [ctx.root, 10])
    assert MapSet.new(partitions) == MapSet.new([ctx.first, ctx.second])

    assert {:ok, locations, :complete} =
             call(ctx, :candidates, [partitions, :outputs, ctx.key, 10])

    assert MapSet.new(locations) == MapSet.new([first, second])
  end

  test "a partition-list refresh finds a writer created after a cached snapshot", ctx do
    assert {:ok, known, :complete} = call(ctx, :partitions, [ctx.root, 10])
    {:ok, {:ok, later}} = CacheIO.run(ctx.pool, {Partition, :create, [ctx.root]}, 0, 1_000)
    location = publish(ctx, later, ctx.key)
    assert {:ok, [], :complete} = call(ctx, :candidates, [known, :outputs, ctx.key, 10])
    assert {:ok, refreshed, :complete} = call(ctx, :partitions, [ctx.root, 10])

    assert {:ok, [^location], :complete} =
             call(ctx, :candidates, [refreshed, :outputs, ctx.key, 10])
  end

  test "retired partitions and staging are absent from discovery", ctx do
    _location = publish(ctx, ctx.first, ctx.key)
    plan = Partition.plan(ctx.second, :outputs, ctx.key)
    {:ok, :ok} = CacheIO.run(ctx.pool, {Partition, :stage, [plan]}, 0, 1_000)
    {:ok, {:ok, _trash}} = CacheIO.run(ctx.pool, {Partition, :retire, [ctx.first]}, 0, 1_000)
    assert {:ok, [second], :complete} = call(ctx, :partitions, [ctx.root, 10])
    assert second == ctx.second

    assert {:ok, [], :complete} =
             call(ctx, :candidates, [[ctx.first, ctx.second], :outputs, ctx.key, 10])
  end

  test "partition and candidate limits report incomplete discovery", ctx do
    _first = publish(ctx, ctx.first, ctx.key)
    _second = publish(ctx, ctx.second, ctx.key)
    assert {:ok, [_partition], :limited} = call(ctx, :partitions, [ctx.root, 1])

    assert {:ok, [_location], :limited} =
             call(ctx, :candidates, [[ctx.first, ctx.second], :outputs, ctx.key, 1])
  end

  test "malformed names cannot become candidate paths and consume scan budget", ctx do
    File.mkdir!(Path.join([ctx.root, "partitions", "not-an-incarnation"]))
    assert {:ok, partitions, :complete} = call(ctx, :partitions, [ctx.root, 10])
    assert MapSet.new(partitions) == MapSet.new([ctx.first, ctx.second])
    location = publish(ctx, ctx.first, ctx.key)
    File.rm_rf!(location.path)
    File.mkdir!(Path.join(Path.dirname(location.path), "invalid-generation"))

    assert {:ok, [], :limited} =
             call(ctx, :candidates, [[ctx.first, ctx.second], :outputs, ctx.key, 1])
  end

  defp publish(ctx, partition, key) do
    plan = Partition.plan(partition, :outputs, key)

    {:ok, location} =
      Generation.publish(ctx.pool, plan, ctx.source, %{}, %{body: 32, metadata: 1_024}, 1_000)

    location
  end

  defp call(ctx, function, args) do
    {:ok, result} = CacheIO.run(ctx.pool, {Discovery, function, args}, 1_000_000, 1_000)
    result
  end
end

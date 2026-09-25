defmodule ImagePipe.Cache.SharedFileSystem.InventoryTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.{Index, Inventory, Partition}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup do
    root = Path.join(System.tmp_dir!(), "shared_inventory_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    {:ok, {:ok, partition}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    %{pool: pool, partition: partition, path: Path.join(partition.path, "inventory")}
  end

  test "bounded inventories round-trip exact locations and warm only hints", ctx do
    candidates = Enum.map(1..5, &location(ctx.partition, &1))
    assert :ok = Inventory.publish(ctx.pool, ctx.partition, candidates, 100, limits(), 1_000)
    assert {:ok, locations} = Inventory.read(ctx.pool, ctx.partition, 105, limits(), 1_000)
    assert locations == Enum.take(candidates, 3)
    assert File.stat!(ctx.path).size <= limits().bytes

    index = Index.new(max_keys: 8, max_bytes: 8_192, max_locations: 2, warm_fraction: 0.25)
    index = Enum.reduce(locations, index, &Index.warm(&2, &1))
    assert %{keys: 2, warm_keys: 2} = Index.stats(index)
  end

  test "a small byte budget truncates the inventory without changing the ranking", ctx do
    candidates = Enum.map(1..5, &location(ctx.partition, &1))
    limits = %{limits() | bytes: 400}
    assert :ok = Inventory.publish(ctx.pool, ctx.partition, candidates, 100, limits, 1_000)
    assert {:ok, locations} = Inventory.read(ctx.pool, ctx.partition, 100, limits, 1_000)
    assert locations == Enum.take(candidates, length(locations))
    refute locations == []
    assert length(locations) < 3
    assert File.stat!(ctx.path).size <= limits.bytes
  end

  test "stale and implausibly future inventories are ignored", ctx do
    assert :ok = publish(ctx)

    assert {:error, :stale_inventory} =
             Inventory.read(ctx.pool, ctx.partition, 161, limits(), 1_000)

    assert {:error, :untrusted_clock} =
             Inventory.read(ctx.pool, ctx.partition, 90, limits(), 1_000)
  end

  test "replacement publishes a complete new inventory", ctx do
    assert :ok = publish(ctx)
    newer = location(ctx.partition, 2)
    assert :ok = Inventory.publish(ctx.pool, ctx.partition, [newer], 110, limits(), 1_000)
    assert {:ok, [^newer]} = Inventory.read(ctx.pool, ctx.partition, 110, limits(), 1_000)
  end

  test "retired partitions cannot be recreated by inventory publication", ctx do
    {:ok, {:ok, _trash}} = CacheIO.run(ctx.pool, {Partition, :retire, [ctx.partition]}, 0, 1_000)
    assert {:error, :enoent} = publish(ctx)
    refute File.exists?(ctx.partition.path)
  end

  test "external payloads cannot smuggle paths, namespaces, or another incarnation", ctx do
    assert :ok = publish(ctx)
    envelope = ctx.path |> File.read!() |> :erlang.binary_to_term()
    [entry] = envelope.entries

    for invalid <- [
          %{envelope | incarnation: String.duplicate("0", 32)},
          %{envelope | entries: [%{entry | key: "../outside"}]},
          %{envelope | entries: [%{entry | generation: "../outside"}]},
          %{envelope | entries: [%{entry | kind: :staging}]},
          %{envelope | entries: List.duplicate(entry, 4)}
        ] do
      File.write!(ctx.path, :erlang.term_to_binary(invalid))

      assert {:error, :corrupt_inventory} =
               Inventory.read(ctx.pool, ctx.partition, 100, limits(), 1_000)
    end
  end

  test "compressed, trailing, and oversized serialized payloads are rejected", ctx do
    assert :ok = publish(ctx)
    valid = File.read!(ctx.path)
    envelope = :erlang.binary_to_term(valid)

    for invalid <- [
          valid <> "trailing",
          :erlang.term_to_binary(Map.put(envelope, :padding, String.duplicate("x", 10_000)), [
            :compressed
          ])
        ] do
      File.write!(ctx.path, invalid)

      assert {:error, :corrupt_inventory} =
               Inventory.read(ctx.pool, ctx.partition, 100, limits(), 1_000)
    end

    File.write!(ctx.path, String.duplicate("x", limits().bytes + 1))

    assert {:error, :inventory_too_large} =
             Inventory.read(ctx.pool, ctx.partition, 100, limits(), 1_000)
  end

  test "uncertain replacement acknowledges only this exact publication", ctx do
    assert :ok = publish(ctx)
    encoded = File.read!(ctx.path)

    operation =
      {Inventory.Storage, :commit, [Path.join(ctx.partition.path, "missing"), ctx.path, encoded]}

    assert {:ok, :ok} = CacheIO.run(ctx.pool, operation, 100_000, 1_000)
    assert :ok = Inventory.publish(ctx.pool, ctx.partition, [], 110, limits(), 1_000)
    assert {:ok, {:error, :enoent}} = CacheIO.run(ctx.pool, operation, 100_000, 1_000)
  end

  test "import reconstructs paths under the advertised partition", ctx do
    assert :ok = publish(ctx)
    envelope = ctx.path |> File.read!() |> :erlang.binary_to_term()
    [entry] = envelope.entries

    File.write!(
      ctx.path,
      :erlang.term_to_binary(%{envelope | entries: [Map.put(entry, :path, "/outside")]})
    )

    assert {:ok, [location]} = Inventory.read(ctx.pool, ctx.partition, 100, limits(), 1_000)

    assert location.path ==
             Path.join(
               Partition.key_directory(ctx.partition, entry.kind, entry.key),
               entry.generation
             )
  end

  defp publish(ctx),
    do:
      Inventory.publish(
        ctx.pool,
        ctx.partition,
        [location(ctx.partition, 1)],
        100,
        limits(),
        1_000
      )

  defp location(partition, number) do
    key = :crypto.hash(:sha256, Integer.to_string(number)) |> Base.encode16(case: :lower)
    plan = Partition.plan(partition, :outputs, key)
    Partition.location(plan.parent, plan.kind, plan.key, plan.generation)
  end

  defp limits, do: %{entries: 3, bytes: 2_048, max_age: 60, clock_skew: 5}
end

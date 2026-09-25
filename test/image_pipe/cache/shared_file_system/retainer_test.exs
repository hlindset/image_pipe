defmodule ImagePipe.Cache.SharedFileSystem.RetainerTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.SharedFileSystem.{Generation, Partition, Retainer}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup do
    root = Path.join(System.tmp_dir!(), "shared_retainer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    tasks = start_supervised!(Task.Supervisor)
    {:ok, {:ok, writer}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    {:ok, {:ok, partition}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)

    %{
      root: root,
      pool: pool,
      tasks: tasks,
      writer: writer,
      partition: partition,
      limits: %{body: 1_024, metadata: 2_048}
    }
  end

  test "real requests admit valuable entries and retire only the local victims", ctx do
    cold = publish(ctx, "cold")
    hot = publish(ctx, "hot")
    client = start_retainer(ctx, cold.size_bytes + 100)
    demand(client, cold, 1)
    assert :scheduled = Retainer.consider(client, cold, 1_000)
    settle(client)
    [old] = local_generations(ctx, cold)

    assert {:rejected, :low_value} = Retainer.consider(client, hot, 1_000)
    demand(client, hot, 2)
    assert :scheduled = Retainer.consider(client, hot, 1_000)
    settle(client)

    stats = Retainer.stats(client, 1_000)
    assert stats.entries == 1
    assert stats.bytes == hot.size_bytes
    assert stats.pending_bytes == 0
    assert stats.cleanup_bytes == 0
    assert stats.failure == nil
    refute File.exists?(old)
    assert File.exists?(cold.location.path)
    assert [_adopted] = local_generations(ctx, hot)
    assert :retained = Retainer.consider(client, hot, 1_000)
  end

  test "duplicate jobs coalesce while demand remains responsive and other work is bounded", ctx do
    first = publish(ctx, "first")
    other = publish(ctx, "other")
    client = start_retainer(ctx, 10_000)
    :ok = :sys.suspend(ctx.pool.pid)

    demand(client, first, 1)
    assert :scheduled = Retainer.consider(client, first, 1_000)
    assert :coalesced = Retainer.consider(client, first, 1_000)
    assert {:error, :saturated} = Retainer.consider(client, other, 1_000)
    assert :ok = Retainer.request(client, :outputs, other.location.key, 1_000)
    assert %{jobs: 1, pending_bytes: bytes, entries: 0} = Retainer.stats(client, 1_000)
    assert bytes == first.size_bytes
    :ok = :sys.resume(ctx.pool.pid)
    settle(client)
    assert [_one_generation] = local_generations(ctx, first)
  end

  test "over-budget entries never start disk adoption", ctx do
    candidate = publish(ctx, "large")
    client = start_retainer(ctx, candidate.size_bytes - 1)
    demand(client, candidate, 5)
    assert {:rejected, :over_cap} = Retainer.consider(client, candidate, 1_000)
    assert %{jobs: 0, bytes: 0, pending_bytes: 0} = Retainer.stats(client, 1_000)
    assert local_generations(ctx, candidate) == []
  end

  test "unknown adoption outcomes keep their charge and stop further writes", ctx do
    candidate = publish(ctx, "entry")
    client = start_retainer(ctx, 10_000)
    assert {:error, _reason} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)
    demand(client, candidate, 1)
    assert :scheduled = Retainer.consider(client, candidate, 1_000)
    settle(client)

    assert %{failure: {:error, :unavailable}, pending_bytes: bytes} =
             Retainer.stats(client, 1_000)

    assert bytes == candidate.size_bytes
    assert {:error, :unavailable} = Retainer.consider(client, candidate, 1_000)
    assert :ok = Retainer.request(client, :outputs, candidate.location.key, 1_000)
  end

  test "failed removal remains charged and cannot enable unbounded replacement", ctx do
    cold = publish(ctx, "cold")
    hot = publish(ctx, "hot")
    client = start_retainer(ctx, cold.size_bytes + 100)
    demand(client, cold, 1)
    assert :scheduled = Retainer.consider(client, cold, 1_000)
    settle(client)
    [old] = local_generations(ctx, cold)
    File.write!(Path.join(old, "unexpected"), "blocks removal")
    demand(client, hot, 2)
    assert :scheduled = Retainer.consider(client, hot, 1_000)
    settle(client)

    assert %{failure: {:error, reason}, cleanup_bytes: bytes, entries: 1} =
             Retainer.stats(client, 1_000)

    assert reason in [:enotempty, :eexist]
    assert bytes == cold.size_bytes
    refute File.exists?(old)
    assert {:error, :unavailable} = Retainer.consider(client, cold, 1_000)

    [unexpected] = Path.wildcard(Path.join([ctx.root, "trash", "*", "unexpected"]))
    File.rm!(unexpected)
    assert :scheduled = Retainer.retry_cleanup(client, 1_000)
    settle(client)
    assert %{failure: nil, cleanup_bytes: 0, jobs: 0} = Retainer.stats(client, 1_000)
    assert :retained = Retainer.consider(client, hot, 1_000)
  end

  defp start_retainer(ctx, bytes) do
    client =
      start_supervised!(
        {Retainer,
         pool: ctx.pool,
         tasks: ctx.tasks,
         partition: ctx.partition,
         limits: ctx.limits,
         max_bytes: bytes}
      )
      |> Retainer.client()

    :erlang.trace(client.pid, true, [:receive])
    client
  end

  defp demand(client, descriptor, count) do
    Enum.each(1..count, fn _ ->
      assert :ok =
               Retainer.request(client, descriptor.location.kind, descriptor.location.key, 1_000)
    end)
  end

  defp settle(client) do
    case :sys.get_state(client.pid) do
      %{job: nil} ->
        :ok

      %{failure: nil, job: %{ref: ref}} ->
        receive_result(client, ref)
        settle(client)

      %{failure: _failure} ->
        :ok
    end
  end

  defp receive_result(%{pid: pid}, ref) do
    assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 2_000
    _ = :sys.get_state(pid)
  end

  defp local_generations(ctx, descriptor) do
    directory =
      Partition.key_directory(ctx.partition, descriptor.location.kind, descriptor.location.key)

    Path.wildcard(Path.join(directory, "*"))
  end

  defp publish(ctx, key) do
    key = Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    plan = Partition.plan(ctx.writer, :outputs, key)
    source = Path.join(ctx.root, key)
    File.write!(source, String.duplicate("x", 400))

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      output_format: :png,
      representation: {:image, :png}
    }

    {:ok, location} = Generation.publish(ctx.pool, plan, source, metadata, ctx.limits, 1_000)
    {:ok, envelope} = Generation.metadata(ctx.pool, location, ctx.limits, 1_000)
    Generation.descriptor(location, envelope)
  end
end

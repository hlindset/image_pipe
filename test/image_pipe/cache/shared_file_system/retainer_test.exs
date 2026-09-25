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

  test "ordinary publication and foreign adoption compete for the same budget", ctx do
    foreign = publish(ctx, "foreign")
    client = start_retainer(ctx, foreign.size_bytes + 100)
    {:ok, envelope} = Generation.metadata(ctx.pool, foreign.location, ctx.limits, 1_000)
    key = Base.encode16(:crypto.hash(:sha256, "generated"), case: :lower)
    assert :ok = Retainer.request(client, :outputs, key, 1_000)

    assert {:ok, local} =
             Retainer.publish(
               client,
               :outputs,
               key,
               Path.join(foreign.location.path, "body"),
               envelope.metadata,
               400,
               1_000
             )

    assert File.exists?(local.path)
    assert {:rejected, :low_value} = Retainer.consider(client, foreign, 1_000)
    demand(client, foreign, 3)
    assert :scheduled = Retainer.consider(client, foreign, 1_000)
    settle(client)
    refute File.exists?(local.path)
    assert %{entries: 1, bytes: bytes} = Retainer.stats(client, 1_000)
    assert bytes == foreign.size_bytes
  end

  test "demand arriving during adoption is preserved by the final admission decision", ctx do
    cold = publish(ctx, "cold")
    candidate = publish(ctx, "candidate")
    client = start_retainer(ctx, cold.size_bytes + 100)
    demand(client, cold, 1)
    assert :scheduled = Retainer.consider(client, cold, 1_000)
    settle(client)
    demand(client, candidate, 2)
    :ok = :sys.suspend(ctx.pool.pid)
    assert :scheduled = Retainer.consider(client, candidate, 1_000)
    demand(client, cold, 10)
    :ok = :sys.resume(ctx.pool.pid)
    settle(client)
    assert [_retained] = local_generations(ctx, cold)
    assert [] = local_generations(ctx, candidate)
    assert %{entries: 1, cleanup_bytes: 0} = Retainer.stats(client, 1_000)
  end

  test "rotation waits for known work and starts a fresh retained set", ctx do
    entry = publish(ctx, "entry")
    client = start_retainer(ctx, 10_000)
    :ok = :sys.suspend(ctx.pool.pid)
    assert :scheduled = Retainer.consider(client, entry, 1_000)
    assert {:error, :saturated} = Retainer.rotate(client, ctx.writer, 1_000)
    :ok = :sys.resume(ctx.pool.pid)
    settle(client)
    {:ok, {:ok, _trash}} = CacheIO.run(ctx.pool, {Partition, :retire, [ctx.partition]}, 0, 1_000)
    {:ok, {:ok, next}} = CacheIO.run(ctx.pool, {Partition, :create, [ctx.root]}, 0, 1_000)
    assert :ok = Retainer.rotate(client, next, 1_000)
    assert %{bytes: 0, entries: 0} = Retainer.stats(client, 1_000)
    assert :scheduled = Retainer.consider(client, entry, 1_000)
    settle(client)
    assert [_local] = local_generations(%{ctx | partition: next}, entry)
  end

  test "an unavailable helper before adoption starts does not create pending writes", ctx do
    candidate = publish(ctx, "entry")
    client = start_retainer(ctx, 10_000)
    assert {:error, _reason} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)
    demand(client, candidate, 1)
    assert :scheduled = Retainer.consider(client, candidate, 1_000)
    settle(client)

    assert %{failure: nil, pending_bytes: 0, entries: 0} = Retainer.stats(client, 1_000)
    assert :ok = Retainer.request(client, :outputs, candidate.location.key, 1_000)
  end

  test "late confirmed publication recovers its charge and permits subsequent writes", ctx do
    _preload = publish(ctx, "preload")
    client = start_retainer(ctx, 10_000, timeout: 200)
    {file, receipt} = blocked_publication(ctx, client)

    try do
      assert %{pending_bytes: bytes, entries: 0} = Retainer.stats(client, 1_000)
      assert bytes > 400
      :ok = :file.write(file, String.duplicate("x", 400))
      :ok = :file.close(file)
      await_completion(client, receipt)
      settle(client)
      assert %{failure: nil, pending_bytes: 0, entries: 1} = Retainer.stats(client, 1_000)
      foreign = publish(ctx, "next")
      assert :scheduled = Retainer.consider(client, foreign, 1_000)
      settle(client)
      assert %{entries: 2} = Retainer.stats(client, 1_000)
    after
      :file.close(file)
    end
  end

  test "a late precommit failure releases pending write accounting", ctx do
    _preload = publish(ctx, "preload")
    client = start_retainer(ctx, 10_000, timeout: 200)
    {file, receipt} = blocked_publication(ctx, client)

    try do
      :ok = :file.write(file, String.duplicate("x", 2_000))
      :ok = :file.close(file)
      await_completion(client, receipt)
      settle(client)
      assert %{failure: nil, pending_bytes: 0, entries: 0} = Retainer.stats(client, 1_000)
    after
      :file.close(file)
    end
  end

  @tag capture_log: true
  test "helper loss during a timed-out publication preserves its uncertain charge", ctx do
    candidate = publish(ctx, "preload")
    client = start_retainer(ctx, 10_000, timeout: 200)
    {file, _receipt} = blocked_publication(ctx, client)

    try do
      assert {:error, _reason} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)
      assert %{failure: failure, pending_bytes: bytes} = Retainer.stats(client, 1_000)
      assert failure != nil
      assert bytes > 400
      assert {:error, :unavailable} = Retainer.consider(client, candidate, 1_000)
    after
      :file.close(file)
    end
  end

  test "a write completing after retirement never becomes owned by the new partition", ctx do
    candidate = publish(ctx, "preload")
    client = start_retainer(ctx, 10_000, timeout: 200)
    {file, receipt} = blocked_publication(ctx, client)

    try do
      {:ok, _retired} = Partition.retire(ctx.partition)
      {:ok, next} = Partition.create(ctx.root)
      assert :ok = Retainer.rotate(client, next, 1_000)
      :ok = :file.write(file, String.duplicate("x", 400))
      :ok = :file.close(file)
      await_completion(client, receipt)
      settle(client)
      assert %{failure: nil, pending_bytes: 0, entries: 0} = Retainer.stats(client, 1_000)
      assert :scheduled = Retainer.consider(client, candidate, 1_000)
      settle(client)
      assert [_local] = local_generations(%{ctx | partition: next}, candidate)
    after
      :file.close(file)
    end
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
    assert :scheduled = Retainer.retry(client, 1_000)
    settle(client)
    assert %{failure: nil, cleanup_bytes: 0, jobs: 0} = Retainer.stats(client, 1_000)
    assert :retained = Retainer.consider(client, hot, 1_000)
  end

  test "pressure cleanup reserves debt and preserves foreign links before recovery", ctx do
    entry = publish(ctx, "entry")
    client = start_retainer(ctx, 10_000)
    assert :scheduled = Retainer.consider(client, entry, 1_000)
    settle(client)
    [local] = local_generations(ctx, entry)
    :sys.suspend(ctx.pool.pid)

    try do
      assert {:ok, :complete} = Retainer.resize(client, 0, 1_000)

      assert %{bytes: 0, capacity: 0, cleanup_bytes: debt, jobs: 1} =
               Retainer.stats(client, 1_000)

      assert debt == entry.size_bytes
      assert {:error, :saturated} = Retainer.consider(client, entry, 1_000)
      assert {:error, :saturated} = Retainer.resize(client, 10_000, 1_000)
    after
      :sys.resume(ctx.pool.pid)
    end

    settle(client)
    refute File.exists?(local)
    assert File.read!(Path.join(entry.location.path, "body")) == String.duplicate("x", 400)
    assert %{cleanup_bytes: 0, jobs: 0} = Retainer.stats(client, 1_000)
    assert {:rejected, :over_cap} = Retainer.consider(client, entry, 1_000)
    assert {:ok, :complete} = Retainer.resize(client, 10_000, 1_000)
    assert :scheduled = Retainer.consider(client, entry, 1_000)
    settle(client)
    assert [_local] = local_generations(ctx, entry)
  end

  defp start_retainer(ctx, bytes, opts \\ []) do
    client =
      start_supervised!(
        {Retainer,
         Keyword.merge(
           [
             pool: ctx.pool,
             tasks: ctx.tasks,
             partition: ctx.partition,
             limits: ctx.limits,
             max_bytes: bytes
           ],
           opts
         )}
      )
      |> Retainer.client()

    :erlang.trace(client.pid, true, [:receive])
    client
  end

  defp blocked_publication(ctx, client) do
    path = Path.join(ctx.root, "blocked-input")
    {_, 0} = System.cmd("mkfifo", [path])
    key = Base.encode16(:crypto.hash(:sha256, "blocked"), case: :lower)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        Retainer.publish(client, :outputs, key, path, metadata(), 400, 1_000)
      end)

    # A write-only open returns only after the helper has opened the read end.
    # Closing after timeout can then deliver EOF instead of stranding a late open.
    {:ok, file} = :file.open(String.to_charlist(path), [:write, :raw, :binary])
    assert {:error, :timeout} = Task.await(task, 2_000)

    settle(client)
    assert %{job: %{receipt: receipt}, failure: {:error, :timeout}} = :sys.get_state(client.pid)
    {file, receipt}
  end

  defp await_completion(%{pid: pid}, receipt) do
    assert_receive {:trace, ^pid, :receive,
                    {:shared_io_complete, ^receipt, {:finished, _result}}},
                   2_000
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

    {:ok, location} = Generation.publish(ctx.pool, plan, source, metadata(), ctx.limits, 1_000)
    {:ok, envelope} = Generation.metadata(ctx.pool, location, ctx.limits, 1_000)
    Generation.descriptor(location, envelope)
  end

  defp metadata do
    %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      output_format: :png,
      representation: {:image, :png}
    }
  end
end

defmodule ImagePipe.Cache.SharedFileSystem.LocationsTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.{Generation, Locations, Partition}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "shared_locations_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    tasks = start_supervised!(Task.Supervisor)

    opts =
      Keyword.merge(
        [root: root, pool: pool, tasks: tasks, search_timeout: 2_000],
        Map.get(context, :location_options, [])
      )

    worker = start_supervised!({Locations, opts})
    {:ok, {:ok, partition}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    source = Path.join(root, "source")
    File.write!(source, "encoded image")

    %{
      root: root,
      pool: pool,
      tasks: tasks,
      worker: worker,
      locations: Locations.client(worker),
      partition: partition,
      source: source,
      key: String.duplicate("a", 64)
    }
  end

  @tag location_options: [max_pending: 1]
  test "asynchronous hints are bounded and expired hints release admission", ctx do
    location = publish(ctx, ctx.partition, ctx.key)
    :ok = :sys.suspend(ctx.worker)

    try do
      assert :ok = Locations.remember_async(ctx.locations, location, 0)
      assert {:error, :saturated} = Locations.remember_async(ctx.locations, location, 1_000)
    after
      :sys.resume(ctx.worker)
    end

    _ = :sys.get_state(ctx.worker)
    assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
    assert :ok = Locations.remember_async(ctx.locations, location, 1_000)
    _ = :sys.get_state(ctx.worker)
    assert {:ok, [^location]} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
  end

  test "discovery is independent of disposable hints and confirmation updates the index", ctx do
    location = publish(ctx, ctx.partition, ctx.key)
    assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
    assert {:ok, [^location], :complete} = discover(ctx)
    assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
    assert :ok = Locations.remember(ctx.locations, location, 1_000)
    assert {:ok, [^location]} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
    assert {:ok, []} = Locations.hints(ctx.locations, :sources, ctx.key, 1_000)
    assert :ok = Locations.forget(ctx.locations, location, 1_000)
    assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
    assert {:ok, [^location], :complete} = discover(ctx)
  end

  test "a cached-list miss refreshes discovery to find new partitions", ctx do
    assert {:ok, [], :complete} = discover(ctx)
    later = partition(ctx)
    location = publish(ctx, later, ctx.key)
    assert {:ok, [^location], :complete} = discover(ctx)
  end

  test "unusable candidates can force a refresh even while the cached list finds names", ctx do
    old = publish(ctx, ctx.partition, ctx.key)
    assert {:ok, [^old], :complete} = discover(ctx)
    later = partition(ctx)
    newer = publish(ctx, later, ctx.key)
    File.rm!(Path.join(old.path, "body"))
    assert {:ok, [^old], :complete} = discover(ctx)
    assert {:ok, candidates, :complete} = discover(ctx, :refresh)
    assert MapSet.new(candidates) == MapSet.new([old, newer])
  end

  @tag location_options: [max_partitions: 1]
  test "truncated partition discovery remains limited when the snapshot is reused", ctx do
    later = partition(ctx)
    _first = publish(ctx, ctx.partition, ctx.key)
    _second = publish(ctx, later, ctx.key)
    assert {:ok, _candidates, :limited} = discover(ctx)
    assert {:ok, _candidates, :limited} = discover(ctx)
  end

  @tag location_options: [max_jobs: 1, max_waiters: 2]
  test "same-key searches coalesce and all waiting and active work is bounded", ctx do
    location = publish(ctx, ctx.partition, ctx.key)
    suspend_pool(ctx)

    try do
      first = search_task(ctx)
      await_request(ctx, first.pid)

      assert {:error, :saturated} =
               Locations.discover(ctx.locations, :sources, ctx.key, :cached, 100)

      assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
      second = search_task(ctx)
      await_request(ctx, second.pid)
      assert %{jobs: 1, waiters: 2} = Locations.stats(ctx.locations, 1_000)
      assert {:error, :saturated} = discover(ctx)

      assert {:error, :saturated} =
               Locations.discover(
                 ctx.locations,
                 :outputs,
                 String.duplicate("b", 64),
                 :cached,
                 100
               )

      :sys.resume(ctx.pool.pid)
      assert {:ok, [^location], :complete} = Task.await(first)
      assert {:ok, [^location], :complete} = Task.await(second)
      assert %{jobs: 0, waiters: 0} = Locations.stats(ctx.locations, 1_000)
    after
      :sys.resume(ctx.pool.pid)
      :erlang.trace(ctx.worker, false, [:receive])
    end
  end

  test "a timed-out caller leaves the search available to a later waiter", ctx do
    location = publish(ctx, ctx.partition, ctx.key)
    suspend_pool(ctx)

    try do
      assert {:error, :timeout} =
               Locations.discover(ctx.locations, :outputs, ctx.key, :cached, 10)

      await_request(ctx)
      second = search_task(ctx)
      await_request(ctx, second.pid)
      :sys.resume(ctx.pool.pid)
      assert {:ok, [^location], :complete} = Task.await(second)
      assert %{jobs: 0, waiters: 0} = Locations.stats(ctx.locations, 1_000)
    after
      :sys.resume(ctx.pool.pid)
      :erlang.trace(ctx.worker, false, [:receive])
    end
  end

  test "caller death releases waiter capacity without cancelling shared work", ctx do
    suspend_pool(ctx)

    try do
      task = search_task(ctx)
      await_request(ctx, task.pid)
      monitor = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}
      assert_receive {:trace, _, :receive, {:DOWN, _, :process, _, :killed}}
      assert %{jobs: 1, waiters: 0} = Locations.stats(ctx.locations, 1_000)
      second = search_task(ctx)
      await_request(ctx, second.pid)
      :sys.resume(ctx.pool.pid)
      assert {:ok, [], :complete} = Task.await(second)
    after
      :sys.resume(ctx.pool.pid)
      :erlang.trace(ctx.worker, false, [:receive])
    end
  end

  @tag location_options: [max_pending: 1]
  test "timed-out queued calls retain admission until dequeue and never update hints", ctx do
    location = publish(ctx, ctx.partition, ctx.key)
    :sys.suspend(ctx.worker)

    try do
      assert {:error, :timeout} = Locations.remember(ctx.locations, location, 1)
      assert {:error, :saturated} = Locations.remember(ctx.locations, location, 1)
    after
      :sys.resume(ctx.worker)
    end

    _ = :sys.get_state(ctx.worker)
    assert {:ok, []} = Locations.hints(ctx.locations, :outputs, ctx.key, 1_000)
  end

  defp suspend_pool(ctx) do
    :sys.suspend(ctx.pool.pid)
    :erlang.trace(ctx.worker, true, [:receive, {:tracer, self()}])
  end

  defp search_task(ctx),
    do: Task.Supervisor.async_nolink(ctx.tasks, fn -> discover(ctx) end)

  defp await_request(ctx, caller \\ self()) do
    worker = ctx.worker

    assert_receive {:trace, ^worker, :receive,
                    {:"$gen_call", {^caller, _}, {:admitted, _, {:discover, _, _, _}, _}}}

    _ = :sys.get_state(worker)
  end

  defp discover(ctx, mode \\ :cached),
    do: Locations.discover(ctx.locations, :outputs, ctx.key, mode, 1_000)

  defp partition(ctx) do
    {:ok, {:ok, partition}} = CacheIO.run(ctx.pool, {Partition, :create, [ctx.root]}, 0, 1_000)
    partition
  end

  defp publish(ctx, partition, key) do
    plan = Partition.plan(partition, :outputs, key)

    {:ok, location} =
      Generation.publish(ctx.pool, plan, ctx.source, %{}, %{body: 32, metadata: 1_024}, 1_000)

    location
  end
end

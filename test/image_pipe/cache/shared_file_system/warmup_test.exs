defmodule ImagePipe.Cache.SharedFileSystem.WarmupTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.SharedFileSystem

  alias ImagePipe.Cache.SharedFileSystem.{
    Generation,
    Inventory,
    InventoryWorker,
    Locations,
    Lookup,
    Retainer,
    Runtime,
    Warmup
  }

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_warmup_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    for name <- [__MODULE__.Writer, __MODULE__.Reader] do
      start_supervised!(
        {SharedFileSystem,
         name: name,
         root: Path.join(root, "shared"),
         local_root: Path.join(root, Atom.to_string(name)),
         clock: fn -> 1_000 end,
         max_retained_bytes: if(name == __MODULE__.Writer, do: 100_000, else: 1_500)}
      )

      {InventoryWorker, worker, _, _} =
        List.keyfind(Supervisor.which_children(name), InventoryWorker, 0)

      :erlang.trace(worker, true, [:receive])
      settle(worker)
    end

    {:ok, writer} = Runtime.context(__MODULE__.Writer)
    {:ok, reader} = Runtime.context(__MODULE__.Reader)
    %{root: root, writer: writer, reader: reader}
  end

  test "ranked inventories warm hints without synthetic demand or adoption", ctx do
    foreign = publish(ctx, ctx.writer, "foreign")
    _local = publish(ctx, ctx.reader, "local")
    assert {:ok, _report} = InventoryWorker.run(__MODULE__.Writer, opts(), :publish)

    assert {:ok, [location]} =
             Inventory.read(
               ctx.writer.pool,
               ctx.writer.partition,
               1_000,
               limits().inventory,
               1_000
             )

    assert location == foreign

    for _ <- 1..3 do
      assert {:ok, %{result: :complete}} = Warmup.run(ctx.reader, 1_000, limits(), 1_000)
    end

    assert {:ok, [^foreign]} = Locations.hints(ctx.reader.locations, :outputs, foreign.key, 1_000)
    assert %{warm_keys: 1} = Locations.stats(ctx.reader.locations, 1_000)

    assert {:ok, envelope} =
             Generation.metadata(ctx.reader.pool, foreign, ctx.reader.limits, 1_000)

    descriptor = Generation.descriptor(foreign, envelope)
    assert {:rejected, :low_value} = Retainer.consider(ctx.reader.retainer, descriptor, 1_000)
    assert %{entries: 1, jobs: 0} = Retainer.stats(ctx.reader.retainer, 1_000)

    assert Path.wildcard(Path.join(ctx.reader.partition.path, "outputs/*/#{foreign.key}/*/body")) ==
             []
  end

  test "missing stale corrupt inventories and invalid generation metadata are harmless", ctx do
    assert {:ok, %{imported: 0}} = Warmup.run(ctx.reader, 1_000, limits(), 1_000)
    foreign = publish(ctx, ctx.writer, "foreign")

    assert :ok =
             Inventory.publish(
               ctx.writer.pool,
               ctx.writer.partition,
               [foreign],
               0,
               limits().inventory,
               1_000
             )

    assert {:ok, %{imported: 0}} = Warmup.run(ctx.reader, 1_000, limits(), 1_000)
    File.write!(Path.join(ctx.writer.partition.path, "inventory"), "broken")
    assert {:ok, %{imported: 0}} = Warmup.run(ctx.reader, 1_000, limits(), 1_000)
    assert {:ok, _report} = InventoryWorker.run(__MODULE__.Writer, opts(), :publish)
    File.write!(Path.join(foreign.path, "meta"), "broken")
    assert {:ok, %{checked: 1, imported: 0}} = Warmup.run(ctx.reader, 1_000, limits(), 1_000)
    assert %{keys: 0} = Locations.stats(ctx.reader.locations, 1_000)
  end

  test "startup warmup runs asynchronously and leaves retention empty", ctx do
    foreign = publish(ctx, ctx.writer, "foreign")
    assert {:ok, _report} = InventoryWorker.run(__MODULE__.Writer, opts(), :publish)
    name = __MODULE__.NewReader

    pid =
      start_supervised!(
        {SharedFileSystem,
         name: name,
         root: ctx.writer.partition.root,
         local_root: Path.join(ctx.root, "new-reader"),
         clock: fn -> 1_000 end}
      )

    {InventoryWorker, worker, _, _} =
      List.keyfind(Supervisor.which_children(pid), InventoryWorker, 0)

    :erlang.trace(worker, true, [:receive])
    settle(worker)
    {:ok, reader} = Runtime.context(name)
    assert {:ok, [^foreign]} = Locations.hints(reader.locations, :outputs, foreign.key, 1_000)
    assert %{entries: 0, jobs: 0} = Retainer.stats(reader.retainer, 1_000)
  end

  test "periodic worker publishes current ranking and warmup honors its candidate budget", ctx do
    first = publish(ctx, ctx.writer, "first")
    second = publish(ctx, ctx.writer, "second")
    :ok = Retainer.request(ctx.writer.retainer, :outputs, first.key, 1_000)

    {InventoryWorker, worker, _, _} =
      List.keyfind(Supervisor.which_children(__MODULE__.Writer), InventoryWorker, 0)

    send(worker, :tick)
    settle(worker)

    assert {:ok, [^first, ^second]} =
             Inventory.read(
               ctx.writer.pool,
               ctx.writer.partition,
               1_000,
               limits().inventory,
               1_000
             )

    assert {:ok, %{checked: 1, imported: 1, candidates: :limited}} =
             Warmup.run(ctx.reader, 1_000, %{limits() | candidates: 1}, 1_000)

    assert {:ok, [^first]} = Locations.hints(ctx.reader.locations, first.kind, first.key, 1_000)
    assert {:ok, []} = Locations.hints(ctx.reader.locations, second.kind, second.key, 1_000)
  end

  test "stalled warmup expires without blocking hints and later requests discover disk", ctx do
    foreign = publish(ctx, ctx.writer, "foreign")
    assert {:ok, _report} = InventoryWorker.run(__MODULE__.Writer, opts(), :publish)
    tasks = start_supervised!(Task.Supervisor)
    :sys.suspend(ctx.reader.pool.pid)

    try do
      warmup =
        Task.Supervisor.async_nolink(tasks, fn ->
          Warmup.run(ctx.reader, 1_000, limits(), 50)
        end)

      assert {:ok, []} = Locations.hints(ctx.reader.locations, :outputs, foreign.key, 1_000)
      assert {:error, :timeout} = Task.await(warmup, 1_000)
      assert %{keys: 0, jobs: 0} = Locations.stats(ctx.reader.locations, 1_000)
    after
      :sys.resume(ctx.reader.pool.pid)
    end

    assert {:hit, reader} = Lookup.output(ctx.reader, foreign.key, 1_000)

    try do
      assert File.read!(reader.path) == String.duplicate("x", 600)

      assert {:ok, [^foreign]} =
               Locations.hints(ctx.reader.locations, :outputs, foreign.key, 1_000)
    after
      assert :ok = Generation.release(ctx.reader.pool, reader, 1_000)
    end
  end

  defp settle(pid) do
    case :sys.get_state(pid) do
      %{job: nil, phase: :publish} ->
        :ok

      %{job: ref} when is_reference(ref) ->
        assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 2_000
        settle(pid)
    end
  end

  defp publish(ctx, context, key) do
    key = Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    path = Path.join(ctx.root, key)
    File.write!(path, String.duplicate("x", 600))

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      representation: {:image, :png},
      output_format: :png
    }

    :ok = Retainer.request(context.retainer, :outputs, key, 1_000)

    {:ok, location} =
      Retainer.publish(context.retainer, :outputs, key, path, metadata, 600, 1_000)

    location
  end

  defp opts,
    do: [
      inventory_max_entries: 16,
      inventory_max_bytes: 4_096,
      inventory_interval: 60_000,
      inactivity_grace: 3_600,
      reclaim_max_partitions: 128,
      reclaim_max_entries: 256,
      warmup_max_partitions: 8,
      warmup_max_candidates: 16,
      warmup_timeout: 1_000,
      timeout: 1_000,
      clock_skew: 5,
      clock: fn -> 1_000 end
    ]

  defp limits,
    do: %{
      partitions: 8,
      candidates: 16,
      inventory: %{entries: 16, bytes: 4_096, max_age: 180, clock_skew: 5}
    }
end

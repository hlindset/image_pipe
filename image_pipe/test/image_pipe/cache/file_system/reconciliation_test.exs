defmodule ImagePipe.Cache.FileSystem.ReconciliationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "reconciliation_#{System.unique_integer([:positive])}")
    prefix = [:"reconciliation_#{System.unique_integer([:positive])}"]
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, prefix: prefix}
  end

  property "reconciliation bounds each batch and brings stored bytes under cap", ctx do
    check all count <- integer(3..12),
              limit <- integer(1..4),
              cap_entries <- integer(1..2),
              max_runs: 12 do
      root = Path.join(ctx.root, "run-#{System.unique_integer([:positive])}")
      prefix = ctx.prefix ++ [:"run_#{System.unique_integer([:positive])}"]
      Enum.each(1..count, &put_entry(key(&1), "body", root: root))
      attach_batches(prefix, self(), false)
      opts = opts(root, prefix, cap_entries * 4, limit)
      pid = start_cache(opts)
      assert :ok = Admission.await_scan(pid)
      batches = batches(pid, [])
      assert Enum.all?(batches, &(&1 <= limit))
      assert Enum.sum(batches) == count - cap_entries
      assert length(Path.wildcard(Path.join(root, "**/*.body"))) == cap_entries
      assert tracked_bytes(pid) == cap_entries * 4
    end
  end

  test "replacement and hit queued during a batch run before the next batch", ctx do
    body = String.duplicate("x", 100)

    for index <- 1..3 do
      assert :ok = put_entry(key(index), body, root: ctx.root)
      {:ok, paths} = FileSystem.paths(key(index), root: ctx.root)
      File.touch!(paths.meta_path, System.os_time(:second) - 100 + index)
    end

    gate = attach_batches(ctx.prefix, self(), true)
    opts = opts(ctx.root, ctx.prefix, 100, 1)
    pid = start_cache(opts)
    opts = Keyword.delete(opts, :telemetry_prefix)
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    try do
      assert_receive {:batch, ^pid, 1}, 1000
      assert {:hit, %{body: ^body}} = FileSystem.get(key(2), opts)

      replacement =
        Task.Supervisor.async_nolink(tasks, fn ->
          :erlang.trace(self(), true, [:send, {:tracer, parent}])
          put_entry(key(2), String.duplicate("y", 100), opts)
        end)

      assert_receive {:trace, _, :send, {:"$gen_call", _, {:commit, _, _}}, ^pid}, 1000
      send(pid, :release_batch)
      assert :ok = Task.await(replacement)
      assert_receive {:batch, ^pid, 1}, 1000
      send(pid, :release_batch)
      assert :ok = Admission.await_scan(pid)
      assert {:hit, %{body: retained}} = FileSystem.get(key(2), opts)
      assert retained == String.duplicate("y", 100)
      assert FileSystem.get(key(3), opts) == :miss
      assert tracked_bytes(pid) == 100
    after
      close_gate(ctx.prefix, gate, pid)
    end
  end

  test "a batch delayed beyond five seconds does not skip the startup sweep", ctx do
    Enum.each(1..3, &put_entry(key(&1), "body", root: ctx.root))
    {:ok, paths} = FileSystem.paths(key(4), root: ctx.root)
    File.mkdir_p!(paths.dir)
    orphan = Path.join(paths.dir, "#{paths.hash}.#{String.duplicate("a", 64)}.body")
    File.write!(orphan, "orphan")
    File.touch!(orphan, System.os_time(:second) - 7200)
    gate = attach_batches(ctx.prefix, self(), true)
    pid = start_cache(opts(ctx.root, ctx.prefix, 4, 1))

    try do
      assert_receive {:batch, ^pid, _count}, 1000
      {:monitors, [{:process, scan}]} = Process.info(pid, :monitors)
      scan_ref = Process.monitor(scan)

      waiter = Task.async(fn -> wait_beyond_timeout(pid) end)

      assert :wait_elapsed = Task.await(waiter, 6000)
      refute_received {:DOWN, ^scan_ref, :process, ^scan, _}
      assert Process.alive?(scan)
      close_gate(ctx.prefix, gate, pid)
      assert :ok = Admission.await_scan(pid)
      refute File.exists?(orphan)
    after
      close_gate(ctx.prefix, gate, pid)
    end
  end

  defp attach_batches(prefix, parent, hold?) do
    gate = :atomics.new(1, [])

    :ok =
      :telemetry.attach(
        {__MODULE__, prefix},
        prefix ++ [:cache, :eviction, :stop],
        fn _, %{count: count}, _, _ ->
          wait? = hold? and :atomics.compare_exchange(gate, 1, 0, 1) == :ok
          send(parent, {:batch, self(), count})

          if wait? do
            receive do
              :release_batch -> :ok
            end

            :atomics.compare_exchange(gate, 1, 1, 0)
          end
        end,
        nil
      )

    on_exit(fn -> detach_batches(prefix) end)
    gate
  end

  defp close_gate(prefix, gate, pid) do
    detach_batches(prefix)
    if :atomics.exchange(gate, 1, 2) == 1, do: send(pid, :release_batch)
  end

  defp wait_beyond_timeout(pid) do
    Admission.await_scan(pid, 5100)
  catch
    :exit, {:timeout, _} -> :wait_elapsed
  end

  defp detach_batches(prefix), do: :telemetry.detach({__MODULE__, prefix})

  defp batches(pid, collected) do
    receive do
      {:batch, ^pid, count} -> batches(pid, [count | collected])
    after
      0 -> collected
    end
  end

  defp start_cache(opts) do
    start_supervised!(FileSystem.child_spec(opts))
    root = Keyword.fetch!(opts, :root)
    [{pid, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    pid
  end

  defp opts(root, prefix, cap, limit),
    do: [
      root: root,
      node_id: "test",
      telemetry_prefix: prefix,
      max_size_bytes: cap,
      window_ratio: 0.0,
      eviction_victim_limit: limit
    ]

  defp key(index),
    do: %Key{hash: Base.encode16(:crypto.hash(:sha256, "key-#{index}"), case: :lower), data: []}

  defp put_entry(key, body, opts) do
    metadata = %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :png
    }

    {:ok, sink} = FileSystem.open_sink(key, metadata, opts)
    {:ok, sink} = FileSystem.write_chunk(sink, body, opts)
    FileSystem.commit_sink(sink, opts)
  end

  defp tracked_bytes(pid) do
    state = :sys.get_state(pid)
    state.window_bytes + state.probationary_bytes + state.protected_bytes
  end
end

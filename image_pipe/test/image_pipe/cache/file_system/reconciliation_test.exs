defmodule ImagePipe.Cache.FileSystem.ReconciliationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.Key
  alias ImagePipe.Test.Caches

  setup do
    root = Path.join(System.tmp_dir!(), "reconciliation_#{System.unique_integer([:positive])}")
    prefix = [:"reconciliation_#{System.unique_integer([:positive])}"]
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, prefix: prefix}
  end

  property "the startup pass bounds each batch and brings stored bytes under cap", ctx do
    check all count <- integer(3..12),
              limit <- integer(1..4),
              cap_entries <- integer(1..2),
              max_runs: 12 do
      root = Path.join(ctx.root, "run-#{System.unique_integer([:positive])}")
      prefix = ctx.prefix ++ [:"run_#{System.unique_integer([:positive])}"]
      Enum.each(1..count, &seed_entry(key(&1), "body", root))
      attach_batches(prefix, self(), false)
      pid = start_cache(opts(root, prefix, cap_entries * 4), limit)
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
      paths = seed_entry(key(index), body, ctx.root)
      File.touch!(paths.meta_path, System.os_time(:second) - 100 + index)
    end

    gate = attach_batches(ctx.prefix, self(), true)
    opts = opts(ctx.root, ctx.prefix, 100)
    pid = start_cache(opts, 1)
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

  test "the startup sweep waits for the scan's reconciliation", ctx do
    Enum.each(1..3, &seed_entry(key(&1), "body", ctx.root))
    orphan = orphan_body(ctx.root)
    gate = attach_batches(ctx.prefix, self(), true)
    attach_sweep(ctx.prefix, self())
    pid = start_cache(opts(ctx.root, ctx.prefix, 4), 1)

    try do
      assert_receive {:batch, ^pid, 1}, 1000
      assert File.exists?(orphan)
      refute_received :swept
      send(pid, :release_batch)
      assert_receive {:batch, ^pid, 1}, 1000
      send(pid, :release_batch)
      assert_receive :swept, 1000
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

  defp attach_sweep(prefix, parent) do
    handler = {__MODULE__, :sweep, prefix}

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:cache, :sweep, :stop],
        fn _, _, _, _ -> send(parent, :swept) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp orphan_body(root) do
    {:ok, paths} = FileSystem.paths(key(:orphan), root: root)
    File.mkdir_p!(paths.dir)
    orphan = Path.join(paths.dir, "#{paths.hash}.#{String.duplicate("a", 64)}.body")
    File.write!(orphan, "orphan")
    File.touch!(orphan, System.os_time(:second) - 7200)
    orphan
  end

  defp detach_batches(prefix), do: :telemetry.detach({__MODULE__, prefix})

  defp batches(pid, collected) do
    receive do
      {:batch, ^pid, count} -> batches(pid, [count | collected])
    after
      0 -> collected
    end
  end

  defp start_cache(opts, batch) do
    start_supervised!(FileSystem.child_spec(opts ++ [window_ratio: 0.0, reconcile_batch: batch]))
    root = Keyword.fetch!(opts, :root)
    [{pid, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    pid
  end

  defp opts(root, prefix, cap),
    do: [root: root, telemetry_prefix: prefix, max_size_bytes: cap]

  defp key(index),
    do: %Key{hash: Base.encode16(:crypto.hash(:sha256, "key-#{index}"), case: :lower), data: []}

  defp metadata do
    %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :png
    }
  end

  # Leaves an entry on disk, as an earlier run would, and returns its paths.
  defp seed_entry(key, body, root), do: Caches.write!([root: root], key, metadata(), body)

  defp put_entry(key, body, opts) do
    {:ok, sink} = FileSystem.open_sink(key, metadata(), opts)
    {:ok, sink} = FileSystem.write_chunk(sink, body, opts)
    FileSystem.commit_sink(sink, opts)
  end

  defp tracked_bytes(pid) do
    state = :sys.get_state(pid)
    state.window_bytes + state.probationary_bytes + state.protected_bytes
  end
end

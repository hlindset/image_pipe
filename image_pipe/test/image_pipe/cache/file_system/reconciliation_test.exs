defmodule ImagePipe.Cache.FileSystem.ReconciliationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Store
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
      pid = start_cache(opts(root, prefix, cap_entries * Policy.charged_bytes(4)), limit)
      assert :ok = Admission.await_scan(pid)
      batches = batches(pid, [])
      assert Enum.all?(batches, &(&1 <= limit))
      assert Enum.sum(batches) == count - cap_entries
      assert length(Path.wildcard(Path.join(root, "**/*.body"))) == cap_entries
      assert stored_bytes(pid) == cap_entries * Policy.charged_bytes(4)
    end
  end

  test "a replacement queued during a batch is decided before the next batch", ctx do
    body = String.duplicate("x", 100)
    keys = Enum.map(1..3, &key/1)
    Enum.each(keys, &seed_entry(&1, body, ctx.root))

    gate = attach_batches(ctx.prefix, self(), true)
    opts = opts(ctx.root, ctx.prefix, Policy.charged_bytes(100))
    pid = start_cache(opts, 1)
    opts = Keyword.delete(opts, :telemetry_prefix)
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    try do
      assert_receive {:batch, ^pid, 1}, 1000
      [kept, other] = Enum.filter(keys, &(FileSystem.get(&1, opts) != :miss))
      assert {:hit, %{body: ^body}} = FileSystem.get(kept, opts)

      replacement =
        Task.Supervisor.async_nolink(tasks, fn ->
          :erlang.trace(self(), true, [:send, {:tracer, parent}])
          put_entry(kept, String.duplicate("y", 100), opts)
        end)

      assert_receive {:trace, _, :send, {:"$gen_call", _, {:decide, _, _, _}}, ^pid}, 1000
      send(pid, :release_batch)

      # The replacement adds no bytes, so it evicts nothing, and the next
      # batch evicts the other entry. Its commit follows its sync, so it may
      # wait behind that batch.
      assert_receive {:batch, ^pid, 1}, 1000
      send(pid, :release_batch)
      assert :ok = Task.await(replacement)
      assert :ok = Admission.await_scan(pid)
      refute_received {:admission_eviction, ^pid, _count}
      assert {:hit, %{body: retained}} = FileSystem.get(kept, opts)
      assert retained == String.duplicate("y", 100)
      assert FileSystem.get(other, opts) == :miss
      assert stored_bytes(pid) == Policy.charged_bytes(100)
    after
      close_gate(ctx.prefix, gate, pid)
    end
  end

  test "the startup sweep ends before the scan reconciles", ctx do
    Enum.each(1..3, &seed_entry(key(&1), "body", ctx.root))
    orphan = orphan_body(ctx.root)
    gate = attach_batches(ctx.prefix, self(), true)
    attach_sweep(ctx.prefix, self())
    pid = start_cache(opts(ctx.root, ctx.prefix, Policy.charged_bytes(4)), 1)

    try do
      assert_receive {:batch, ^pid, 1}, 1000
      assert_received :swept
      refute File.exists?(orphan)
      send(pid, :release_batch)
      assert_receive {:batch, ^pid, 1}, 1000
      send(pid, :release_batch)
      assert :ok = Admission.await_scan(pid)
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
        fn
          _, %{count: count}, %{trigger: :startup}, _ ->
            wait? = hold? and :atomics.compare_exchange(gate, 1, 0, 1) == :ok
            send(parent, {:batch, self(), count})

            if wait? do
              receive do
                :release_batch -> :ok
              end

              :atomics.compare_exchange(gate, 1, 1, 0)
            end

          _, %{count: count}, %{trigger: :admission}, _ ->
            send(parent, {:admission_eviction, self(), count})
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

    orphan =
      Path.join(paths.dir, Store.body_filename(paths.hash, String.duplicate("a", 64), 6, 0))

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
    start_supervised!(FileSystem.child_spec(opts ++ [reconcile_batch: batch]))
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

  defp stored_bytes(pid), do: :sys.get_state(pid).stored_bytes
end

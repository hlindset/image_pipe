defmodule ImagePipe.Cache.FileSystem.RescanTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "rescan_#{System.unique_integer([:positive])}")
    prefix = [:"rescan_#{System.unique_integer([:positive])}"]
    on_exit(fn -> File.rm_rf!(root) end)
    attach_rescan(prefix, self())
    %{root: root, prefix: prefix}
  end

  test "a re-scan counts entries a peer wrote and evicts down to the cap", ctx do
    pid = start_cache(opts(ctx.root, ctx.prefix, 12))
    assert :ok = Admission.await_scan(pid)

    # A peer sharing the root writes without this node's Admission.
    Enum.each(1..5, &assert(:ok = put_entry(key(&1), "body", root: ctx.root)))
    assert tracked_bytes(pid) == 0

    assert %{adopted: 5, dropped: 0, resynced: 0} = rescan(pid)
    assert tracked_bytes(pid) == 12
    assert length(bodies(ctx.root)) == 3
  end

  test "a re-scan forgets entries a peer deleted and resizes ones it replaced", ctx do
    Enum.each(1..2, &assert(:ok = put_entry(key(&1), "body", root: ctx.root)))
    pid = start_cache(opts(ctx.root, ctx.prefix, 100))
    assert :ok = Admission.await_scan(pid)
    assert tracked_bytes(pid) == 8

    assert :ok = Store.delete(key(1), root: ctx.root)
    assert :ok = put_entry(key(2), "longer body", root: ctx.root)

    assert %{adopted: 0, dropped: 1, resynced: 1} = rescan(pid)
    assert tracked_bytes(pid) == byte_size("longer body")
  end

  test "a re-scan keeps an entry committed after the directory was listed", ctx do
    pid = start_cache(opts(ctx.root, ctx.prefix, 100))
    assert :ok = Admission.await_scan(pid)
    assert :ok = put_entry(key(1), "body", opts(ctx.root, ctx.prefix, 100))

    # The listing missed the entry, so the re-scan asks Admission to check it.
    assert GenServer.call(pid, {:rescan_resync, [key(1).hash]}) == {0, 0}
    assert tracked_bytes(pid) == 4
  end

  test "a re-scan deletes left-over files", ctx do
    pid = start_cache(opts(ctx.root, ctx.prefix, 100))
    assert :ok = Admission.await_scan(pid)
    orphan = orphan_body(ctx.root)

    rescan(pid)
    refute File.exists?(orphan)
  end

  defp rescan(pid) do
    send(pid, :rescan)
    assert_receive {:rescanned, metadata}, 5_000
    metadata
  end

  defp attach_rescan(prefix, parent) do
    handler = {__MODULE__, prefix}

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:cache, :rescan, :stop],
        fn _, _, metadata, _ -> send(parent, {:rescanned, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp start_cache(opts) do
    start_supervised!(FileSystem.child_spec(opts))
    root = Keyword.fetch!(opts, :root)
    [{pid, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    pid
  end

  defp opts(root, prefix, cap),
    do: [
      root: root,
      node_id: "test",
      telemetry_prefix: prefix,
      max_size_bytes: cap,
      window_ratio: 0.0
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

  defp orphan_body(root) do
    {:ok, paths} = FileSystem.paths(key(:orphan), root: root)
    File.mkdir_p!(paths.dir)
    orphan = Path.join(paths.dir, "#{paths.hash}.#{String.duplicate("a", 64)}.body")
    File.write!(orphan, "orphan")
    File.touch!(orphan, System.os_time(:second) - 7200)
    orphan
  end

  defp bodies(root), do: Path.wildcard(Path.join(root, "**/*.body"))

  defp tracked_bytes(pid) do
    state = :sys.get_state(pid)
    state.window_bytes + state.probationary_bytes + state.protected_bytes
  end
end

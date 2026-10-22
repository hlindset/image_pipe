defmodule ImagePipe.Cache.FileSystem.MemoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Memo
  alias ImagePipe.Cache.FileSystem.Root
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key

  setup context do
    root = Path.join(System.tmp_dir!(), "image_pipe_memo_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    opts =
      [root: root, max_size_bytes: Map.get(context, :max_size_bytes, 1_000_000_000)] ++
        Map.get(context, :options, [])

    {:ok, opts} = FileSystem.validate_options(opts)
    start_supervised!(FileSystem.child_spec(opts))
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    assert :ok = Admission.await_scan(admission)
    %{opts: opts, root: root, admission: admission}
  end

  test "a repeated hit reads the entry's metadata from memory", %{opts: opts} do
    key = key("a")
    assert :ok = put_entry(key, "body", [{"vary", "Accept"}], opts)
    assert {:hit, %{headers: [{"vary", "Accept"}]}} = get(key, opts)

    # Behind the cache's back, so only a read from disk would see it.
    {:ok, paths} = FileSystem.paths(key, opts)
    {:ok, metadata} = Store.metadata(key, opts)
    rewritten = %{metadata | headers: [{"x-rewritten", "1"}]}
    File.write!(paths.meta_path, :erlang.term_to_binary(rewritten))

    assert {:hit, %{headers: [{"vary", "Accept"}]}} = get(key, opts)
  end

  test "a write that replaces an entry with the same body is read back", %{opts: opts} do
    key = key("b")
    assert :ok = put_entry(key, "body", [{"vary", "Accept"}], opts)
    assert {:hit, _entry} = get(key, opts)

    assert :ok = put_entry(key, "body", [{"x-new", "1"}], opts)
    assert {:hit, %{headers: [{"x-new", "1"}]}} = get(key, opts)
  end

  test "an eviction forgets the victim's metadata", ctx do
    key = key("e")
    assert :ok = put_entry(key, "body", [], ctx.opts)
    assert {:hit, _entry} = get(key, ctx.opts)
    assert Memo.get(ctx.root, key.hash) != nil

    # A lowered cap evicts every entry.
    :sys.replace_state(ctx.admission, &%{&1 | max_size_bytes: 1})
    assert :ok = GenServer.call(ctx.admission, :reconcile_to_cap)
    assert Memo.get(ctx.root, key.hash) == nil
  end

  test "a sweep's removals forget their metadata", %{opts: opts, root: root, admission: admission} do
    key = key("1")
    assert :ok = put_entry(key, "body", [], opts)
    assert {:hit, _entry} = get(key, opts)
    {:ok, metadata} = Store.metadata(key, opts)

    GenServer.cast(admission, {:swept, [{key.hash, metadata.body_filename}]})
    _ = :sys.get_state(admission)
    assert Memo.get(root, key.hash) == nil
  end

  test "a fill that raced a change to its entry is dropped", %{root: root} do
    key = String.duplicate("8", 64)
    epoch = Memo.epoch(root, key)
    Memo.forget(root, [key])

    Memo.remember(root, key, epoch, :stale)
    assert Memo.get(root, key) == nil

    Memo.remember(root, key, Memo.epoch(root, key), :current)
    assert Memo.get(root, key) == :current
  end

  test "a fill that spans a restart of the cache process is dropped", %{opts: opts, root: root} do
    key = String.duplicate("7", 64)
    epoch = Memo.epoch(root, key)

    # Admission owns the table, so restarting it recreates the table.
    {:cache, cache, :supervisor, _modules} =
      opts |> Root.name() |> Supervisor.which_children() |> List.keyfind(:cache, 0)

    id = {Admission, root}
    :ok = Supervisor.terminate_child(cache, id)
    {:ok, _admission} = Supervisor.restart_child(cache, id)

    Memo.remember(root, key, epoch, :stale)
    assert Memo.get(root, key) == nil
  end

  test "a remembered entry whose body is gone reads as a miss", %{opts: opts, root: root} do
    key = key("2")
    assert :ok = put_entry(key, "body", [], opts)
    assert {:hit, _entry} = get(key, opts)

    {:ok, paths} = FileSystem.paths(key, opts)
    {:ok, metadata} = Store.metadata(key, opts)
    File.rm!(Path.join(paths.dir, metadata.body_filename))

    assert get(key, opts) == :miss
    assert Memo.get(root, key.hash) == nil
  end

  test "a remembered entry whose body was truncated is invalid", %{opts: opts} do
    key = key("3")
    assert :ok = put_entry(key, "body", [], opts)
    assert {:hit, _entry} = get(key, opts)

    {:ok, paths} = FileSystem.paths(key, opts)
    {:ok, metadata} = Store.metadata(key, opts)
    File.write!(Path.join(paths.dir, metadata.body_filename), "bo")

    assert get(key, opts) == {:error, {:invalid_metadata, :body_byte_size_mismatch}}
  end

  test "keeps at most its limit of entries", %{root: root} do
    limit = Memo.limit(root)

    for n <- 0..limit do
      key = Base.encode16(<<n::256>>, case: :lower)
      Memo.remember(root, key, Memo.epoch(root, key), :value)
    end

    assert Memo.size(root) == limit
  end

  test "the limit follows the cache's size", %{root: root} do
    assert Memo.limit(root) == 20_000
  end

  @tag max_size_bytes: 100
  test "a small cache keeps a floor of entries", %{root: root} do
    assert Memo.limit(root) == 1_000
  end

  @tag max_size_bytes: 100_000_000_000
  test "a large cache's limit is capped", %{root: root} do
    assert Memo.limit(root) == 50_000
  end

  @tag options: [max_remembered_entries: 7]
  test "max_remembered_entries sets the limit", %{root: root} do
    assert Memo.limit(root) == 7
  end

  defp get(key, opts), do: FileSystem.get(key, opts)

  defp key(digit), do: %Key{hash: String.duplicate(digit, 64), data: []}

  defp put_entry(key, body, headers, opts) do
    metadata =
      struct!(Entry.Metadata,
        content_type: "image/webp",
        headers: headers,
        created_at: ~U[2026-04-29 10:15:00Z],
        output_format: :webp
      )

    with {:ok, state} <- FileSystem.open_sink(key, metadata, opts),
         {:ok, state} <- FileSystem.write_chunk(state, body, opts) do
      FileSystem.commit_sink(state, opts)
    end
  end
end

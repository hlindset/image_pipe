defmodule ImagePipe.Cache.InputRefreshTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source
  alias ImagePipe.Source.Record

  setup do
    root = Path.join(System.tmp_dir!(), "input_refresh_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = [root: root, node_id: "test", max_size_bytes: 100, window_ratio: 1.0]
    start_supervised!(FileSystem.child_spec(pool))
    tasks = start_supervised!({Task.Supervisor, []})
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    assert :ok = Admission.await_scan(admission)
    File.mkdir_p!(root)
    path = Path.join(root, "source")
    File.write!(path, "image")
    key = %Key{hash: String.duplicate("a", 64), data: []}
    config = [input_cache: {FileSystem, pool}]
    original = record("image", 1000)
    assert :ok = Input.put(key, path, original, 25, config)

    %{
      pool: pool,
      key: key,
      config: config,
      admission: admission,
      tasks: tasks,
      original: original
    }
  end

  test "refresh preserves stored bytes and cost while updating source evidence", ctx do
    {:ok, before} = Store.metadata(ctx.key, ctx.pool)
    refreshed = record("image", 1060)
    assert :ok = Input.refresh(ctx.key, refreshed, ctx.config)
    assert {:ok, metadata} = Store.metadata(ctx.key, ctx.pool)
    assert metadata == %{before | source_record: refreshed}
  end

  test "refresh for different source bytes leaves the current record intact", ctx do
    assert :ok = Input.refresh(ctx.key, record("different", 1060), ctx.config)
    assert Input.metadata(ctx.key, ctx.config) == ctx.original
  end

  test "a refresh prepared before replacement cannot overwrite the new record", ctx do
    previous = Input.metadata(ctx.key, ctx.config)
    replacement = record("new image", 1060)
    path = Path.join(Keyword.fetch!(ctx.pool, :root), "source")
    File.write!(path, "new image")
    assert :ok = Input.put(ctx.key, path, replacement, 25, ctx.config)

    assert :ok =
             Store.refresh_source_record(ctx.key, previous, record("image", 1060), ctx.pool)

    assert Input.metadata(ctx.key, ctx.config) == replacement
  end

  test "refresh queued after invalidation cannot restore deleted metadata", ctx do
    parent = self()
    target = ctx.admission
    :sys.suspend(ctx.admission)

    {deletion, refresh} =
      try do
        deletion = queued(ctx.tasks, parent, fn -> Input.discard(ctx.key, ctx.config) end)
        assert_receive {:trace, _, :send, {:"$gen_call", _, _}, ^target}, 1000

        refresh =
          queued(ctx.tasks, parent, fn ->
            Input.refresh(ctx.key, record("image", 1060), ctx.config)
          end)

        assert_receive {:trace, _, :send, {:"$gen_call", _, _}, ^target}, 1000
        {deletion, refresh}
      after
        :sys.resume(ctx.admission)
      end

    assert Task.await_many([deletion, refresh]) == [:ok, :ok]
    assert Store.metadata(ctx.key, ctx.pool) == :miss
    assert :sys.get_state(ctx.admission).window_bytes == 0
  end

  defp queued(tasks, parent, fun) do
    Task.Supervisor.async_nolink(tasks, fn ->
      :erlang.trace(self(), true, [:send, {:tracer, parent}])
      fun.()
    end)
  end

  defp record(bytes, now) do
    {:ok, source, _config} = Source.from_input({:binary, bytes}, sources: %{})
    Record.new(source, :crypto.hash(:sha256, bytes), nil, now)
  end
end

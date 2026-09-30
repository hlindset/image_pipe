defmodule ImagePipe.Cache.FileSystemConcurrentCommitTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "cache_commit_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [root: root, node_id: "test", max_size_bytes: 1000, window_ratio: 1.0]
    prefix = [:"cache_concurrent_#{System.unique_integer([:positive])}"]
    start_supervised!(FileSystem.child_spec(Keyword.put(opts, :telemetry_prefix, prefix)))
    tasks = start_supervised!({Task.Supervisor, []})
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), {root, "test"})
    key = %Key{hash: String.duplicate("a", 64), data: []}
    %{root: root, opts: opts, tasks: tasks, admission: admission, key: key, prefix: prefix}
  end

  test "overlapping A to B to A commits retain the final body", %{
    root: root,
    opts: opts,
    tasks: tasks,
    admission: admission,
    key: key
  } do
    assert :ok = put_entry(key, "original", opts)

    parent = self()
    :sys.suspend(admission)

    {first, second} =
      try do
        first = queued_commit(tasks, parent, key, "replacement", opts)
        assert_receive {:trace, _, :send, {:"$gen_call", _, _}, ^admission}, 1000
        second = queued_commit(tasks, parent, key, "original", opts)
        assert_receive {:trace, _, :send, {:"$gen_call", _, _}, ^admission}, 1000
        {first, second}
      after
        :sys.resume(admission)
      end

    assert Task.await_many([first, second]) == [:ok, :ok]
    assert {:hit, %{body: "original"}} = FileSystem.get(key, opts)
    state = :sys.get_state(admission)
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 8
    assert [body_path] = Path.wildcard(Path.join(root, "**/*.body"))
    assert File.read!(body_path) == "original"
  end

  test "parallel replacements keep disk bodies and accounting consistent", ctx do
    results =
      Task.Supervisor.async_stream_nolink(
        ctx.tasks,
        1..100,
        fn index ->
          hash = :crypto.hash(:sha256, "key-#{rem(index, 4)}") |> Base.encode16(case: :lower)
          key = %Key{hash: hash, data: []}
          put_entry(key, String.duplicate("#{rem(index, 7)}", 100), ctx.opts)
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))

    for index <- 0..3 do
      hash = :crypto.hash(:sha256, "key-#{index}") |> Base.encode16(case: :lower)
      assert {:hit, %{body: body}} = FileSystem.get(%Key{hash: hash, data: []}, ctx.opts)
      assert byte_size(body) == 100
    end

    bodies = Path.wildcard(Path.join(ctx.root, "**/*.body"))
    assert length(bodies) == 4
    assert Enum.sum(Enum.map(bodies, &File.stat!(&1).size)) == 400
    state = :sys.get_state(ctx.admission)
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 400
  end

  test "a read racing eviction does not restore deleted entry accounting", ctx do
    assert :ok = put_entry(ctx.key, String.duplicate("a", 500), ctx.opts)
    parent = self()
    handler = make_ref()
    event = ctx.prefix ++ [:cache, :admission, :stop]

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, _, _ ->
          send(parent, :admitted)

          receive do
            :release -> :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    other = %Key{hash: String.duplicate("b", 64), data: []}

    writer =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        put_entry(other, String.duplicate("b", 800), ctx.opts)
      end)

    try do
      assert_receive :admitted
      :telemetry.detach(handler)
      assert {:hit, %{body: body}} = FileSystem.get(ctx.key, ctx.opts)
      assert byte_size(body) == 500
    after
      send(ctx.admission, :release)
    end

    assert Task.await(writer) == :ok
    state = :sys.get_state(ctx.admission)
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 800
    assert FileSystem.get(ctx.key, ctx.opts) == :miss
    assert {:hit, _} = FileSystem.get(other, ctx.opts)
  end

  test "failed publication leaves admission accounting unchanged", ctx do
    assert :ok = put_entry(ctx.key, "original", ctx.opts)
    body = "replacement"
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    body_path = Path.join([ctx.root, "aa", "aa", "#{ctx.key.hash}.#{sha}.body"])
    File.mkdir!(body_path)

    assert {:error, _} = put_entry(ctx.key, body, ctx.opts)
    assert {:hit, %{body: "original"}} = FileSystem.get(ctx.key, ctx.opts)
    state = :sys.get_state(ctx.admission)
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 8
  end

  @tag capture_log: true
  test "admission termination cleans prepared temporary files", ctx do
    parent = self()
    admission = ctx.admission
    :sys.suspend(admission)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        :erlang.trace(self(), true, [:send, {:tracer, parent}])

        put_entry(ctx.key, "body", ctx.opts)
      end)

    assert_receive {:trace, _, :send, {:"$gen_call", _, _}, ^admission}, 1000
    temporary_files = Path.join(ctx.root, "**/*.tmp")
    assert Path.wildcard(temporary_files, match_dot: true) != []
    ref = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
    assert {:error, :admission_unavailable} = Task.await(task)
    assert Path.wildcard(temporary_files, match_dot: true) == []
  end

  defp queued_commit(tasks, parent, key, body, opts) do
    Task.Supervisor.async_nolink(tasks, fn ->
      :erlang.trace(self(), true, [:send, {:tracer, parent}])
      put_entry(key, body, opts)
    end)
  end

  defp put_entry(key, body, opts) do
    metadata = %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :png,
      representation: {:image, :png}
    }

    with {:ok, sink} <- FileSystem.open_sink(key, metadata, opts),
         {:ok, sink} <- FileSystem.write_chunk(sink, body, opts) do
      FileSystem.commit_sink(sink, opts)
    end
  end
end

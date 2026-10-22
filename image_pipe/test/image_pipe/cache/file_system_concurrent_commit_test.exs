defmodule ImagePipe.Cache.FileSystemConcurrentCommitTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Policy
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Key

  setup do
    root = Path.join(System.tmp_dir!(), "cache_commit_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [root: root, max_size_bytes: 4 * Policy.charged_bytes(100)]
    prefix = [:"cache_concurrent_#{System.unique_integer([:positive])}"]

    start_supervised!(FileSystem.child_spec(opts ++ [telemetry_prefix: prefix]))

    tasks = start_supervised!({Task.Supervisor, []})
    [{admission, _}] = Registry.lookup(FileSystem.registry_name(root), root)
    key = %Key{hash: String.duplicate("a", 64), data: []}
    %{root: root, opts: opts, tasks: tasks, admission: admission, key: key, prefix: prefix}
  end

  test "overlapping A to B to A commits retain the final body", %{
    root: root,
    opts: opts,
    tasks: tasks,
    admission: admission,
    key: key,
    prefix: prefix
  } do
    assert :ok = put_entry(key, "original", opts)
    parent = self()
    handler = hold_decision(prefix, parent)

    try do
      # The first decision is held while the second write queues its own.
      first = queued_commit(tasks, parent, key, "replacement", opts)
      assert_receive {:deciding, ^admission}, 1000
      second = queued_commit(tasks, parent, key, "original", opts)
      second_pid = second.pid
      assert_receive {:trace, ^second_pid, :send, {:"$gen_call", _, {:decide, _, _, _}}, _}, 1000

      # Releasing it lets the first write sync and queue its commit while
      # the second decision is held, so the commits arrive in order.
      send(admission, :decide)
      assert_receive {:deciding, ^admission}, 1000
      first_pid = first.pid
      assert_receive {:trace, ^first_pid, :send, {:"$gen_call", _, {:commit, _, _}}, _}, 1000
      send(admission, :decide)

      assert Task.await_many([first, second]) == [:ok, :ok]
    after
      :telemetry.detach(handler)
    end

    assert {:hit, %{body: "original"}} = FileSystem.get(key, opts)
    assert :sys.get_state(admission).stored_bytes == Policy.charged_bytes(8)
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
    assert :sys.get_state(ctx.admission).stored_bytes == 4 * Policy.charged_bytes(100)
  end

  test "a read racing eviction does not restore deleted entry accounting", ctx do
    # Either entry fits under the cap, but not both.
    a_size = 4 * 4096
    b_size = 5 * 4096
    assert :ok = put_entry(ctx.key, String.duplicate("a", a_size), ctx.opts)
    other = %Key{hash: String.duplicate("b", 64), data: []}
    # A first sighting of the other key loses the gate. Once another request
    # misses it, its next write wins.
    assert {:ok, :rejected} = put_entry(other, String.duplicate("b", b_size), ctx.opts)
    FileSystem.missed(other, ctx.opts)
    _state = :sys.get_state(ctx.admission)
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

    writer =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        put_entry(other, String.duplicate("b", b_size), ctx.opts)
      end)

    try do
      assert_receive :admitted
      :telemetry.detach(handler)
      assert {:hit, %{body: body}} = FileSystem.get(ctx.key, ctx.opts)
      assert byte_size(body) == a_size
    after
      send(ctx.admission, :release)
    end

    assert Task.await(writer) == :ok
    assert :sys.get_state(ctx.admission).stored_bytes == Policy.charged_bytes(b_size)
    assert FileSystem.get(ctx.key, ctx.opts) == :miss
    assert {:hit, _} = FileSystem.get(other, ctx.opts)
  end

  test "failed publication leaves admission accounting unchanged", ctx do
    assert :ok = put_entry(ctx.key, "original", ctx.opts)
    body = "replacement"
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    body_filename = Store.body_filename(ctx.key.hash, sha, byte_size(body), 0)
    body_path = Path.join([ctx.root, "aa", "aa", body_filename])
    File.mkdir!(body_path)

    assert {:error, _} = put_entry(ctx.key, body, ctx.opts)
    assert {:hit, %{body: "original"}} = FileSystem.get(ctx.key, ctx.opts)
    assert :sys.get_state(ctx.admission).stored_bytes == Policy.charged_bytes(8)
  end

  test "a commit that times out while queued is still published", ctx do
    assert :ok = put_entry(ctx.key, "original", ctx.opts)
    parent = self()
    admission = ctx.admission
    opts = Keyword.put(ctx.opts, :commit_timeout, 0)
    handler = hold_decision(ctx.prefix, parent)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        :erlang.trace(self(), true, [:send, {:tracer, parent}])
        put_entry(ctx.key, "replacement", opts)
      end)

    try do
      # Admission is held inside the decision. A suspend queued now runs
      # once the decision replies, before the writer can send its commit.
      assert_receive {:deciding, ^admission}, 1000
      :erlang.trace(admission, true, [:receive])
      suspender = Task.async(fn -> :sys.suspend(admission) end)
      assert_receive {:trace, ^admission, :receive, {:system, _from, :suspend}}, 1000
      :erlang.trace(admission, false, [:receive])
      send(admission, :decide)
      Task.await(suspender)

      assert_receive {:trace, _, :send, {:"$gen_call", _, {:commit, prepared, _}}, ^admission},
                     1000

      assert {:error, :admission_timeout} = Task.await(task)
      assert File.exists?(prepared.temp_body_path)
      assert File.exists?(prepared.temp_meta_path)
    after
      :telemetry.detach(handler)
      :sys.resume(admission)
    end

    assert :sys.get_state(admission).stored_bytes == Policy.charged_bytes(11)
    assert {:hit, %{body: "replacement"}} = FileSystem.get(ctx.key, ctx.opts)
    assert Path.wildcard(Path.join(ctx.root, "**/*.tmp"), match_dot: true) == []
  end

  # Holds Admission inside its next decision until it receives `:decide`.
  defp hold_decision(prefix, parent) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:cache, :admission, :stop],
        fn _event, _measurements, _metadata, _config ->
          send(parent, {:deciding, self()})
          receive(do: (:decide -> :ok))
        end,
        nil
      )

    handler
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
    with {:ok, sink} <- written_sink(key, body, opts) do
      FileSystem.commit_sink(sink, opts)
    end
  end

  defp written_sink(key, body, opts) do
    metadata = %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: :png,
      representation: {:image, :png}
    }

    with {:ok, sink} <- FileSystem.open_sink(key, metadata, opts) do
      FileSystem.write_chunk(sink, body, opts)
    end
  end
end

defmodule ImagePipe.Cache.WriterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Publication
  alias ImagePipe.Test.Caches

  @content_type "text/plain"

  setup do
    root = Path.join(System.tmp_dir!(), "cache_writer_#{System.unique_integer([:positive])}")
    images = Path.join(root, "images")
    File.mkdir_p!(images)
    Image.new!(24, 16, color: :red) |> Image.write!(Path.join(images, "red.png"))
    on_exit(fn -> File.rm_rf!(root) end)

    prefix = [__MODULE__, :"run_#{System.unique_integer([:positive])}"]
    handler = make_ref()
    test = self()

    :telemetry.attach(
      handler,
      prefix ++ [:cache, :stage],
      fn _event, _measurements, metadata, _config -> send(test, {:stage, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{
      root: Path.join(root, "cache"),
      originals: Path.join(root, "originals"),
      images: images,
      prefix: prefix
    }
  end

  test "a response completes while the cache's storage is stalled", ctx do
    opts =
      Caches.start!(
        sources: [
          media: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: ctx.images, root_id: "media"]
          ]
        ],
        cache: [root: ctx.root]
      )

    admission = admission(ctx.root)
    :sys.suspend(admission)

    conn = conn(:get, "/w=8/format=png/src/red.png")
    conn = ImagePipe.Plug.call(conn, Caches.plug(opts))
    assert conn.status == 200
    assert conn.resp_body |> Image.from_binary!() |> Image.width() == 8
    assert stored_bodies(ctx.root) == []

    :sys.resume(admission)
    Caches.await_writes(opts)
    refute stored_bodies(ctx.root) == []
  end

  test "drops a write whose unfinished bytes would pass the cache's limit", ctx do
    # The pending limit is a twentieth of max_size_bytes: 100 bytes.
    opts = cache_opts(ctx, max_size_bytes: 2_000)
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)

    assert Cache.write_chunk(sink, String.duplicate("x", 200), opts) == nil
    assert_receive {:stage, %{cache: :stage_dropped, reason: :pending_limit, pool: :output}}

    Caches.await_writes(opts)
    assert {:miss, _key} = Cache.lookup_entry(key(), opts)
    assert Writers.pending(ctx.root) == 0
  end

  test "drops a write the client gets more than 8 MB ahead of", ctx do
    opts = cache_opts(ctx, [])
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    :sys.suspend(sink.writer)
    chunk = String.duplicate("x", 1_048_576)

    sink = Enum.reduce(1..10, sink, fn _index, sink -> Cache.write_chunk(sink, chunk, opts) end)

    assert sink == nil
    assert_receive {:stage, %{cache: :stage_dropped, reason: :lagging}}

    :sys.resume(writer_of(ctx.root))
    Caches.await_writes(opts)
    assert {:miss, _key} = Cache.lookup_entry(key(), opts)
    assert Writers.pending(ctx.root) == 0
  end

  test "drops a write that outlives its maximum age", ctx do
    opts = cache_opts(ctx, [])
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    sink = Cache.write_chunk(sink, "body", opts)

    ref = Process.monitor(sink.writer)
    send(sink.writer, :expire)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    assert_receive {:stage, %{cache: :stage_dropped, reason: :deadline}}

    assert :ok = Cache.commit_sink(sink, opts)
    assert {:miss, _key} = Cache.lookup_entry(key(), opts)
    assert Writers.pending(ctx.root) == 0
  end

  test "opens the entry's file after the request moves on, and reports a failure", ctx do
    opts = cache_opts(ctx, [])
    {:ok, paths} = FileSystem.paths(key(), Keyword.fetch!(opts, :cache))
    File.mkdir_p!(Path.dirname(paths.dir))
    File.write!(paths.dir, "not a directory")

    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    assert sink != nil
    assert_receive {:stage, %{cache: :stage_error, error: _error}}

    assert :ok = Cache.commit_sink(Cache.write_chunk(sink, "body", opts), opts)
    Caches.await_writes(opts)
    assert stored_bodies(ctx.root) == []
  end

  test "a shutdown doesn't finish a write into a root another node took over", ctx do
    opts = cache_opts(ctx, [])
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    ref = Process.monitor(sink.writer)
    :sys.suspend(sink.writer)

    Process.exit(sink.writer, :shutdown)
    sink = Cache.write_chunk(sink, "body", opts)
    assert :ok = Cache.commit_sink(sink, opts)
    Owner.refuse(ctx.root)
    on_exit(fn -> Owner.accept(ctx.root) end)

    :sys.resume(sink.writer)
    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
    assert stored_bodies(ctx.root) == []
  end

  test "an abort after the writer dropped the write reports nothing more", ctx do
    opts = cache_opts(ctx, [])
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    sink = Cache.write_chunk(sink, "body", opts)

    ref = Process.monitor(sink.writer)
    send(sink.writer, :expire)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    assert_receive {:stage, %{cache: :stage_dropped, reason: :deadline}}

    assert :ok = Cache.abort_sink(sink, :client_closed, opts)
    refute_received {:stage, %{cache: :stage_abandoned}}
  end

  test "a write whose writer was killed counts nothing against the restarted writers", ctx do
    opts = cache_opts(ctx, [])
    sink = Cache.open_sink(key(), {:complete_body, @content_type}, [], opts)
    sink = Cache.write_chunk(sink, "body", opts)

    # A writer still stuck after the shutdown timeout is killed without
    # running its terminate, and the cache's writers start again.
    ref = Process.monitor(sink.writer)
    Process.exit(sink.writer, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}
    restart_writers(ctx.root)

    sink = Cache.write_chunk(sink, String.duplicate("x", 1_000), opts)
    assert :ok = Cache.commit_sink(sink, opts)
    assert Writers.pending(ctx.root) == 0
  end

  describe "a fetch's writes" do
    test "skip the original and run the rest at the writer limit", ctx do
      opts = originals_opts(ctx)
      test = self()

      blockers =
        for n <- 1..64 do
          spec = Supervisor.child_spec({Task, fn -> receive(do: (:stop -> :ok)) end}, id: n)
          {:ok, pid} = Writers.start_child(ctx.originals, spec)
          pid
        end

      on_exit(fn -> Enum.each(blockers, &send(&1, :stop)) end)

      Cache.publish("source", nil, staged(ctx, test), opts)
      assert_received :record
      refute_received :original
      assert_received {:stage, %{cache: :stage_dropped, reason: :writer_limit, pool: :input}}

      Cache.publish("source", nil, fn -> send(test, :invalidated) end, opts)
      assert_received :invalidated
    end

    test "skip the original without an originals cache, and reserve nothing", ctx do
      opts = cache_opts(ctx, [])
      test = self()

      Cache.publish("source", nil, staged(ctx, test), opts)
      Caches.await_writes(opts)

      assert_received :record
      refute_received :original
      refute_received {:stage, _metadata}
      assert Writers.pending(ctx.root) == 0
    end

    test "run an invalidation after their lease expired, and drop the rest", ctx do
      opts = originals_opts(ctx)
      test = self()
      expired = make_ref()

      Cache.publish("source", expired, {:invalidate, fn -> send(test, :invalidated) end}, opts)
      Cache.publish("source", expired, fn -> send(test, :remembered) end, opts)
      Caches.await_writes(opts)

      assert_received :invalidated
      refute_received :remembered
      assert_received {:stage, %{cache: :stage_dropped, reason: :deadline}}
    end

    test "release their reservation when the request never hands them over" do
      test = self()

      for stop <- [:cancel, :exit] do
        writer = spawn(&Publication.await/0)
        send(writer, {:finish, fn -> send(test, {:released, stop}) end})
        waiting(writer)

        case stop do
          :cancel -> send(writer, :cancel)
          :exit -> Process.exit(writer, :shutdown)
        end

        assert_receive {:released, ^stop}
      end
    end
  end

  test "unfinished writes count against max_size_bytes", ctx do
    opts = cache_opts(ctx, max_size_bytes: 10_000)
    cache = Keyword.fetch!(opts, :cache)
    assert :ok = commit(cache, key("a"), String.duplicate("a", 5_000))

    # Another write holds 400 bytes, so the next entry no longer fits beside
    # the first, and loses to it.
    :ok = Writers.reserve(Writers.counter(ctx.root), 400)
    assert {:ok, :rejected} = commit(cache, key("b"), String.duplicate("b", 4_700))

    Writers.release(Writers.counter(ctx.root), 400)
    assert :ok = commit(cache, key("b"), String.duplicate("b", 4_700))
    assert {:hit, entry} = Cache.lookup_entry(key("b"), opts)
    Entry.close(entry)
  end

  # Returns once `pid` has handled its messages and waits for more, so it
  # traps exits by then.
  defp waiting(pid) do
    case Process.info(pid, [:message_queue_len, :status]) do
      [message_queue_len: 0, status: :waiting] -> :ok
      _busy -> waiting(pid)
    end
  end

  defp originals_opts(ctx) do
    Cache.validate_config!(
      Caches.start!(
        cache: [root: ctx.root],
        input_cache: [root: ctx.originals],
        telemetry_prefix: ctx.prefix
      )
    )
  end

  # A staged original in a real file, whose write and record report here.
  defp staged(ctx, test) do
    path = Path.join(ctx.originals <> "_staging", "original")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "original bytes")
    {:staged, path, fn _path -> send(test, :original) end, fn -> send(test, :record) end}
  end

  defp cache_opts(ctx, cache) do
    Cache.validate_config!(
      Caches.start!(cache: [root: ctx.root] ++ cache, telemetry_prefix: ctx.prefix)
    )
  end

  # Commits through the cache's Admission from this process, which holds no
  # pending bytes.
  defp commit(cache, key, body) do
    {:ok, sink} = FileSystem.open_sink(key, metadata(), cache)
    {:ok, sink} = FileSystem.write_chunk(sink, body, cache)
    FileSystem.commit_sink(sink, cache)
  end

  defp metadata do
    %Entry.Metadata{
      content_type: @content_type,
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: nil,
      representation: {:complete_body, @content_type}
    }
  end

  defp key(seed \\ "a"),
    do: %Key{hash: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower), data: []}

  defp admission(root) do
    [{pid, _value}] = Registry.lookup(FileSystem.registry_name(root), root)
    pid
  end

  defp restart_writers(root) do
    [cache] =
      for {:cache, pid, :supervisor, _modules} <- Supervisor.which_children(root_supervisor(root)),
          do: pid

    :ok = Supervisor.terminate_child(cache, Writers)
    {:ok, _pid} = Supervisor.restart_child(cache, Writers)
  end

  defp root_supervisor(root), do: FileSystem.Root.name(root: root)

  defp writer_of(root) do
    [pid] = Writers.writers(root)
    pid
  end

  defp stored_bodies(root), do: Path.wildcard(Path.join(root, "**/*.body"))
end

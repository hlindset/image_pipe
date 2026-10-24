defmodule ImagePipe.Delivery.CoordinatorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Test.CacheObserver

  @mb 1024 * 1024

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:processing, :execute, :stop],
      &__MODULE__.stopped/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{tasks: tasks, pool: pool, config: [processing_pool: pool, telemetry_prefix: prefix]}
  end

  def stopped(_event, _measurements, metadata, test),
    do: send(test, {:processing_stopped, metadata.result})

  test "status diagnostics leave out the configuration and its credentials" do
    secret = "fake-origin-secret"
    config = [sources: [origin: [options: [req_options: [headers: [{"x-api-key", secret}]]]]]]
    build_fun = fn _pump -> :ok end

    {:ok, pid} =
      Coordinator.start(build_fun, self(), nil, [], RequestContext.capture(), config)

    refute inspect(:sys.get_status(pid), limit: :infinity) =~ secret
    GenServer.stop(pid)
  end

  test "the encode ends its turn before the client reads past the first chunk", context do
    test = self()

    build = fn pump ->
      try do
        pump.(["one", "two", "three"], "image/jpeg", resolved(), nil)
      after
        send(test, :cleanup)
      end
    end

    assert {:ok, stream} = Delivery.stream(build, nil, context.config)
    assert stream.first_chunk == "one"
    assert_receive :cleanup
    assert_receive {:processing_stopped, :ok}
    assert %{active: 0} = ProcessingPool.stats(context.pool)

    assert stream.next.() == {:chunk, "two"}
    assert stream.next.() == {:chunk, "three"}
    assert stream.next.() == :done
  end

  test "requests waiting for the output are released before the client reads it", context do
    config = CacheObserver.observe(context.config)
    hash = String.duplicate("c3", 32)
    key = %ImagePipe.Cache.Key{hash: hash, data: []}
    cache = {__MODULE__, make_ref()}
    opts = [telemetry_prefix: [__MODULE__, :waiters]]
    {:leader, lease} = OutputWork.join(cache, hash, opts)

    follower =
      Task.Supervisor.async_nolink(context.tasks, fn -> OutputWork.join(cache, hash, opts) end)

    build = fn pump -> pump.(["one", "two"], "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(build, key, config, output_lease: lease)

    assert Task.await(follower) == :ready
    assert CacheObserver.stored_body(config, hash) == "onetwo"
    assert stream.next.() == {:chunk, "two"}
    assert stream.next.() == :done
  end

  test "cancelling mid-encode releases the requests waiting for the output", context do
    config = CacheObserver.observe(context.config)
    hash = String.duplicate("e5", 32)
    key = %ImagePipe.Cache.Key{hash: hash, data: []}
    cache = {__MODULE__, make_ref()}
    opts = [telemetry_prefix: [__MODULE__, :cancel_waiters]]
    {:leader, lease} = OutputWork.join(cache, hash, opts)

    follower =
      Task.Supervisor.async_nolink(context.tasks, fn -> OutputWork.join(cache, hash, opts) end)

    test = self()

    source =
      Stream.map(["one", "two"], fn
        "two" ->
          send(test, {:gated, self()})
          receive do: (:continue -> "two")

        chunk ->
          chunk
      end)

    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(build, key, config, output_lease: lease)
    assert_receive {:gated, worker}
    assert stream.cancel.() == :ok

    assert Task.await(follower) == :bypass
    send(worker, :continue)
    assert_receive {:cache_abort, ^hash}
  end

  @tag :tmp_dir
  test "output past the memory window is spooled to disk and read back in order",
       %{tmp_dir: dir} = context do
    path = Path.join(dir, "spool.tmp")
    {coordinator, first} = start_session(context, chunks(), spool_path: path)
    assert first == chunk(1)

    assert_receive {:processing_stopped, :ok}
    assert %{active: 0} = ProcessingPool.stats(context.pool)
    refute File.exists?(path)
    assert held_bytes(coordinator) <= 5 * @mb

    assert read_rest(coordinator) == IO.iodata_to_binary(Enum.map(2..12, &chunk/1))
  end

  @tag :tmp_dir
  test "without a usable spool the encode keeps pace with the client",
       %{tmp_dir: dir} = context do
    for session <- [[], [spool_path: Path.join([dir, "missing", "spool.tmp"])]] do
      {coordinator, _first} = start_session(context, chunks(), session)
      assert %{active: 1} = ProcessingPool.stats(context.pool)
      assert read_rest(coordinator) == IO.iodata_to_binary(Enum.map(2..12, &chunk/1))
      assert_receive {:processing_stopped, :ok}
    end
  end

  test "a chunk larger than the memory window is delivered without a spool", context do
    large = :binary.copy("x", 5 * @mb)
    {coordinator, "one"} = start_session(context, ["one", large, "two"], [])
    assert read_rest(coordinator) == large <> "two"
  end

  test "a client that leaves after the encode keeps the stored entry", context do
    config = CacheObserver.observe(context.config)
    hash = String.duplicate("d4", 32)
    key = %ImagePipe.Cache.Key{hash: hash, data: []}
    test = self()

    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        build = fn pump -> pump.(["one", "two"], "image/jpeg", resolved(), nil) end
        {:ok, _stream} = Delivery.stream(build, key, config)
        send(test, :prepared)
        receive do: (:finish -> :ok)
      end)

    assert_receive :prepared
    assert_receive {:cache_put, ^hash, "onetwo"}
    Task.shutdown(owner, :brutal_kill)
    refute_received {:cache_abort, ^hash}
    assert CacheObserver.stored_body(config, hash) == "onetwo"
  end

  test "an encode failure after buffered chunks reaches the client", context do
    source =
      Stream.map(["one", "two", "three"], fn
        "three" -> raise "encode failure"
        chunk -> chunk
      end)

    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(build, nil, context.config)
    assert_receive {:processing_stopped, :processing_error}

    # The failure can reach the session before or after the client takes the
    # buffered chunk.
    result =
      case stream.next.() do
        {:chunk, "two"} -> stream.next.()
        result -> result
      end

    assert {:error, {:encode, _exception, _stacktrace}} = result
  end

  defp start_session(context, chunks, session) do
    build = fn pump -> pump.(chunks, "image/png", resolved(), nil) end

    {:ok, coordinator} =
      Coordinator.start(build, self(), nil, session, RequestContext.capture(), context.config)

    {:ok, %{first_chunk: first}} = Coordinator.prepare(coordinator)
    {coordinator, first}
  end

  defp read_rest(coordinator, acc \\ []) do
    case Coordinator.next(coordinator) do
      {:chunk, chunk} -> read_rest(coordinator, [acc, chunk])
      :done -> IO.iodata_to_binary(acc)
    end
  end

  # 12 MB, made as the encode pulls it, so only the coordinator holds it.
  defp chunks, do: Stream.map(1..12, &chunk/1)
  defp chunk(index), do: :binary.copy(<<index>>, @mb)

  # Bytes of the binaries the coordinator holds.
  defp held_bytes(coordinator) do
    :erlang.garbage_collect(coordinator)
    {:binary, binaries} = Process.info(coordinator, :binary)
    binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()
  end

  defp resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end
end

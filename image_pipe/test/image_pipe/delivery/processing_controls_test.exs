defmodule ImagePipe.Delivery.ProcessingControlsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Test.PlugFixture.CacheProbe

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:processing, :execute, :stop],
      fn _, _, metadata, pid -> send(pid, {:processing_stopped, metadata.result}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{tasks: tasks, prefix: prefix}
  end

  test "retains a slot until EOF cleanup and explicit cancellation", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    for action <- [:eof, :cancel] do
      build = fn pump ->
        try do
          pump.(["one", "two"], "image/jpeg", resolved(), nil)
        after
          send(test, :cleanup)
        end
      end

      assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
      assert %{active: 1} = ProcessingPool.stats(pool)

      assert {:error, {:processing, :overloaded}} =
               ProcessingPool.run(pool, fn -> flunk() end, [])

      case action do
        :eof ->
          assert stream.next.() == {:chunk, "two"}
          assert stream.next.() == :done

        :cancel ->
          assert stream.cancel.() == :ok
      end

      assert_receive :cleanup
      assert_receive {:processing_stopped, _result}
      assert %{active: 0} = ProcessingPool.stats(pool)
    end
  end

  test "an idle prepared stream retains the processing timeout for its next pull", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    build = fn pump -> pump.(["one", "two"], "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
    assert stream.first_chunk == "one"

    # Expire the idle stream's budget now instead of racing a short timeout
    # against stream preparation.
    [{token, %{deadline: deadline}}] = Map.to_list(:sys.get_state(pool).jobs)
    send(pool, {:deadline, token, :active, deadline})

    assert_receive {:processing_stopped, :timeout}
    assert stream.next.() == {:error, {:processing, :timeout}}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "owner death gracefully cancels prepared streams and releases admission", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        build = fn pump ->
          try do
            pump.(["one", "two"], "image/jpeg", resolved(), nil)
          after
            send(test, :cleanup)
          end
        end

        {:ok, _stream} = Delivery.stream(self(), build, nil, config)
        send(test, :prepared)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :prepared
    Task.shutdown(owner, :brutal_kill)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :cancelled}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "failure after the first chunk releases the slot", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]

    source =
      Stream.map(["one", "two"], fn
        "one" -> "one"
        "two" -> raise "encode failure"
      end)

    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
    assert {:error, _} = stream.next.()
    assert_receive {:processing_stopped, :processing_error}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "timeout before the first chunk returns promptly and lets resource cleanup finish later",
       context do
    pool =
      start_supervised!(
        {ProcessingPool, max_concurrency: 1, max_queue: 0, processing_timeout: 40}
      )

    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    build = fn pump ->
      try do
        send(test, {:working, self()})

        receive do
          :continue -> pump.(["one", "two"], "image/jpeg", resolved(), nil)
        end
      after
        send(test, :cleanup)
      end
    end

    job =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        Delivery.stream(self(), build, nil, config)
      end)

    assert_receive {:working, worker}
    ref = Process.monitor(worker)
    assert Task.await(job) == {:error, {:processing, :timeout}}
    assert %{active: 1} = ProcessingPool.stats(pool)
    # The coordinator's old forced-halt timer must not kill admitted native work.
    refute_receive {:DOWN, ^ref, :process, ^worker, _}, 1_100
    refute_received :cleanup
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :timeout}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "timeout between chunks drops the late chunk and keeps resource brackets intact",
       context do
    pool =
      start_supervised!(
        {ProcessingPool, max_concurrency: 1, max_queue: 0, processing_timeout: 40}
      )

    store = :ets.new(:timeout_cache, [:set, :public])
    key = %ImagePipe.Cache.Key{hash: "timeout-test", data: []}

    config = [
      processing_pool: pool,
      telemetry_prefix: context.prefix,
      cache: {CacheProbe, store: store}
    ]

    test = self()

    source =
      Stream.map(["one", "two"], fn
        "one" ->
          "one"

        "two" ->
          send(test, {:working, self()})

          receive do
            :continue -> "two"
          end
      end)

    build = fn pump ->
      try do
        pump.(source, "image/jpeg", resolved(), nil)
      after
        send(test, :cleanup)
      end
    end

    assert {:ok, stream} = Delivery.stream(self(), build, key, config)
    assert_receive {:cache_open_sink, ^key, _metadata}
    job = Task.Supervisor.async_nolink(context.tasks, fn -> stream.next.() end)
    assert_receive {:working, worker}
    assert Task.await(job) == {:error, {:processing, :timeout}}
    assert_receive {:cache_abort, ^key}
    assert %{active: 1} = ProcessingPool.stats(pool)
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :timeout}
    assert %{active: 0} = ProcessingPool.stats(pool)
    assert :ets.tab2list(store) == []
    refute_received {:cache_put, ^key, _body}
  end

  test "explicit cancellation detaches a blocked admitted producer without skipping cleanup",
       context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    build = fn pump ->
      try do
        send(test, {:working, self()})

        receive do
          :continue -> pump.(["one"], "image/jpeg", resolved(), nil)
        end
      after
        send(test, :cleanup)
      end
    end

    {:ok, coordinator} = Coordinator.start(build, self(), nil, RequestContext.capture(), config)
    job = Task.Supervisor.async_nolink(context.tasks, fn -> Coordinator.prepare(coordinator) end)
    assert_receive {:working, worker}
    ref = Process.monitor(worker)
    assert Coordinator.cancel(coordinator) == :ok
    assert Task.await(job) == {:error, {:session, :cancelled}}
    assert %{active: 1} = ProcessingPool.stats(pool)
    refute_receive {:DOWN, ^ref, :process, ^worker, _}, 1_100
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :cancelled}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "cancelling a queued producer removes it without entering its resource brackets",
       context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    build = fn pump -> pump.(["one"], "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(self(), build, nil, config)

    {:ok, coordinator} =
      Coordinator.start(fn _pump -> flunk() end, self(), nil, RequestContext.capture(), config)

    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        context.prefix ++ [:processing, :admission, :start],
        fn _event, _measurements, _metadata, target -> send(target, :queued_request) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    job = Task.Supervisor.async_nolink(context.tasks, fn -> Coordinator.prepare(coordinator) end)
    assert_receive :queued_request
    assert %{active: 1, queued: 1} = ProcessingPool.stats(pool)
    assert Coordinator.cancel(coordinator) == :ok
    assert Task.await(job) == {:error, {:session, :cancelled}}
    assert %{active: 1, queued: 0} = ProcessingPool.stats(pool)
    assert stream.cancel.() == :ok
    assert_receive {:processing_stopped, :cancelled}
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

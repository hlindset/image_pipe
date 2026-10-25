defmodule ImagePipe.Delivery.ProcessingControlsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Test.CacheObserver

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

  test "retains a slot through the encode and its cleanup, past cancellation", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    source = gated(["one", "two"])

    build = fn pump ->
      try do
        pump.(source, "image/jpeg", resolved(), nil)
      after
        send(test, :cleanup)
      end
    end

    assert {:ok, stream} = Delivery.stream(build, nil, config)
    assert_receive {:gated, worker}
    assert %{active: 1} = ProcessingPool.stats(pool)

    assert {:error, {:processing, :overloaded}} =
             ProcessingPool.run(pool, fn -> flunk() end, [])

    assert stream.cancel.() == :ok
    assert %{active: 1} = ProcessingPool.stats(pool)
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :cancelled}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "a stream that finishes after its deadline, before the timer fires, times out",
       context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    source = gated(["one", "two"])
    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(build, nil, config)
    assert_receive {:gated, worker}

    # Move the deadline into the past without firing its timer, as when the
    # pool is busy at the moment the deadline passes.
    past = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(pool, fn state ->
      jobs = Map.new(state.jobs, fn {token, job} -> {token, %{job | deadline: past}} end)
      %{state | jobs: jobs}
    end)

    send(worker, :continue)
    assert stream.next.() == {:chunk, "two"}
    assert stream.next.() == {:error, {:processing, :timeout}}
    assert_receive {:processing_stopped, :timeout}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "owner death gracefully cancels prepared streams and releases admission", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    source = gated(["one", "two"])

    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        build = fn pump ->
          try do
            pump.(source, "image/jpeg", resolved(), nil)
          after
            send(test, :cleanup)
          end
        end

        {:ok, _stream} = Delivery.stream(build, nil, config)
        send(test, :prepared)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :prepared
    assert_receive {:gated, worker}
    Task.shutdown(owner, :brutal_kill)
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :cancelled}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "generation cost excludes the wait for a processing slot", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = CacheObserver.observe(processing_pool: pool, telemetry_prefix: context.prefix)
    queue_wait_us = 200_000
    test = self()

    Task.Supervisor.async_nolink(context.tasks, fn ->
      ProcessingPool.within(pool, self(), config, fn ->
        send(test, :holding)
        await_queued(pool)
        # Holds the slot so the stream below queues; nothing races this.
        Process.sleep(div(queue_wait_us, 1_000))
      end)
    end)

    assert_receive :holding
    build = fn pump -> pump.(["one"], "image/jpeg", resolved(), nil) end
    key = %ImagePipe.Cache.Key{hash: String.duplicate("a1", 32), data: []}
    assert {:ok, stream} = Delivery.stream(build, key, config)
    :done = stream.next.()

    assert_receive {:cache_open_sink, _hash, %{cost_us: cost_us}}
    assert cost_us < queue_wait_us
  end

  defp await_queued(pool) do
    case ProcessingPool.stats(pool) do
      %{queued: 0} -> await_queued(pool)
      _queued -> :ok
    end
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
    assert {:ok, stream} = Delivery.stream(build, nil, config)
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
        Delivery.stream(build, nil, config)
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
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})

    hash = String.duplicate("b2", 32)
    key = %ImagePipe.Cache.Key{hash: hash, data: []}
    config = CacheObserver.observe(processing_pool: pool, telemetry_prefix: context.prefix)

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

    assert {:ok, stream} = Delivery.stream(build, key, config)
    job = Task.Supervisor.async_nolink(context.tasks, fn -> stream.next.() end)
    assert_receive {:working, worker}

    # Expire the budget while the second chunk is in progress instead of racing
    # a short timeout against the first.
    [{token, %{deadline: deadline}}] = Map.to_list(:sys.get_state(pool).jobs)
    send(pool, {:deadline, token, :active, deadline})

    assert Task.await(job) == {:error, {:processing, :timeout}}
    assert_receive {:cache_abort, ^hash}
    assert %{active: 1} = ProcessingPool.stats(pool)
    send(worker, :continue)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :timeout}
    assert %{active: 0} = ProcessingPool.stats(pool)
    assert CacheObserver.stored_body(config, hash) == nil
    refute_received {:cache_put, ^hash, _body}
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

    {:ok, coordinator} =
      Coordinator.start(build, self(), nil, [], RequestContext.capture(), config)

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
    source = gated(["one", "two"])
    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(build, nil, config)
    assert_receive {:gated, worker}

    {:ok, coordinator} =
      Coordinator.start(
        fn _pump -> flunk() end,
        self(),
        nil,
        [],
        RequestContext.capture(),
        config
      )

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
    send(worker, :continue)
    assert_receive {:processing_stopped, :cancelled}
  end

  # Holds the encode before every chunk after the first until the producer
  # gets `:continue`.
  defp gated(chunks) do
    test = self()

    chunks
    |> Stream.with_index()
    |> Stream.map(fn
      {chunk, 0} ->
        chunk

      {chunk, _index} ->
        send(test, {:gated, self()})
        receive do: (:continue -> chunk)
    end)
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

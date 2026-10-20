defmodule ImagePipe.ProcessingPoolTest do
  use ExUnit.Case, async: true

  alias ImagePipe.ProcessingPool

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    prefix = [__MODULE__, test]
    Process.put(:pool_telemetry, prefix)
    owner = self()
    handler = make_ref()

    :telemetry.attach_many(
      handler,
      [prefix ++ [:processing, :admission, :start], prefix ++ [:processing, :admission, :stop]],
      fn event, _measurements, metadata, owner -> send(owner, {List.last(event), metadata}) end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{tasks: tasks}
  end

  test "bounds running jobs and rejects overflow", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 0)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker}
    assert {:error, {:processing, :overloaded}} = ProcessingPool.run(pool, fn -> flunk() end, [])
    send(worker, :continue)
    assert Task.await(first) == :ok
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "queues a job beyond max_concurrency by default", %{tasks: tasks} do
    pool = pool(max_concurrency: 1)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker1}
    second = blocked(tasks, pool, :second)
    await_queued(pool, 1)

    send(worker1, :continue)
    assert Task.await(first) == :ok
    assert_receive {:started, :second, worker2}
    send(worker2, :continue)
    assert Task.await(second) == :ok
  end

  test "admits queued jobs in FIFO order", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 2)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker1}
    second = blocked(tasks, pool, :second)
    await_queued(pool, 1)
    third = blocked(tasks, pool, :third)
    await_queued(pool, 2)
    assert {:error, {:processing, :overloaded}} = ProcessingPool.run(pool, fn -> flunk() end, [])

    send(worker1, :continue)
    assert Task.await(first) == :ok
    assert_receive {:started, :second, worker2}
    refute_received {:started, :third, _}
    send(worker2, :continue)
    assert Task.await(second) == :ok
    assert_receive {:started, :third, worker3}
    send(worker3, :continue)
    assert Task.await(third) == :ok
  end

  test "queue expiry does not run the callback or leak capacity", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 1, queue_timeout: 1_000)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker}

    assert {:error, {:processing, :queue_timeout}} =
             ProcessingPool.run(pool, fn -> flunk() end, [])

    send(worker, :continue)
    assert Task.await(first) == :ok
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "processing deadline replies while retaining capacity until the callback finishes", %{
    tasks: tasks
  } do
    pool = pool(max_concurrency: 1, max_queue: 0, processing_timeout: 40)
    job = blocked(tasks, pool, :timed)
    assert_receive {:started, :timed, worker}
    ref = Process.monitor(worker)
    assert Task.await(job) == {:error, {:processing, :timeout}}
    assert %{active: 1} = ProcessingPool.stats(pool)
    refute_received {:DOWN, ^ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> flunk() end, []) == {:error, {:processing, :overloaded}}
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "owner death removes queued work and retains active work until it finishes", %{
    tasks: tasks
  } do
    pool = pool(max_concurrency: 1, max_queue: 1)
    active = blocked(tasks, pool, :active)
    assert_receive {:started, :active, worker}
    waiting = blocked(tasks, pool, :waiting)
    await_queued(pool, 1)
    worker_ref = Process.monitor(worker)
    Task.shutdown(waiting, :brutal_kill)
    assert_receive {:stop, %{result: :cancelled}}
    Task.shutdown(active, :brutal_kill)
    assert %{active: 1, queued: 0} = ProcessingPool.stats(pool)
    refute_received {:DOWN, ^worker_ref, :process, ^worker, _}
    send(worker, :continue)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
    refute_received {:started, :waiting, _}
  end

  test "queued work expires while timed-out computation retains its slot", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 1, processing_timeout: 40, queue_timeout: 80)
    job = blocked(tasks, pool, :timed)
    assert_receive {:started, :timed, worker}
    assert Task.await(job) == {:error, {:processing, :timeout}}

    assert ProcessingPool.run(pool, fn -> flunk() end, []) ==
             {:error, {:processing, :queue_timeout}}

    assert %{active: 1, queued: 0} = ProcessingPool.stats(pool)
    ref = Process.monitor(worker)
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "cancellation remains the outcome after the processing deadline", %{tasks: tasks} do
    prefix = Process.get(:pool_telemetry)
    owner = self()
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:processing, :execute, :stop],
      fn _event, _measurements, metadata, owner -> send(owner, {:execution_stop, metadata}) end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    pool = pool(max_concurrency: 1, processing_timeout: 40)
    job = blocked(tasks, pool, :cancelled)
    assert_receive {:started, :cancelled, worker}
    assert :ok = ProcessingPool.cancel(pool, worker)
    refute_receive {:execution_stop, _}, 60
    assert %{active: 1} = ProcessingPool.stats(pool)
    send(worker, :continue)
    assert Task.await(job) == {:error, {:processing, :cancelled}}
    assert_receive {:execution_stop, %{result: :cancelled}}
  end

  test "a late exception releases the retained slot without reaching the timed-out caller", %{
    tasks: tasks
  } do
    pool = pool(max_concurrency: 1, max_queue: 0, processing_timeout: 40)
    test = self()

    job =
      Task.Supervisor.async_nolink(tasks, fn ->
        result =
          ProcessingPool.run(
            pool,
            fn ->
              send(test, {:started, self()})

              receive do
                :continue -> raise "late failure"
              end
            end,
            []
          )

        send(test, {:returned, result})

        receive do
          :check_mailbox -> send(test, {:mailbox, Process.info(self(), :messages)})
        end
      end)

    assert_receive {:started, worker}
    assert_receive {:returned, {:error, {:processing, :timeout}}}
    ref = Process.monitor(worker)
    assert %{active: 1} = ProcessingPool.stats(pool)
    send(worker, :continue)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    send(job.pid, :check_mailbox)
    assert_receive {:mailbox, {:messages, []}}
    Task.await(job)
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "callback failures release capacity and retain their exception" do
    pool = pool(max_concurrency: 1)

    assert_raise RuntimeError, "broken", fn ->
      ProcessingPool.run(pool, fn -> raise "broken" end, [])
    end

    assert ProcessingPool.run(pool, fn -> {:error, {:decode, :bad}} end, []) ==
             {:error, {:decode, :bad}}

    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "worker death releases admission even without callback cleanup", %{tasks: tasks} do
    pool = pool(max_concurrency: 1)
    job = blocked(tasks, pool, :dying)
    assert_receive {:started, :dying, worker}
    Process.exit(worker, :kill)
    assert Task.await(job) == {:error, {:processing, :worker_down}}
    assert ProcessingPool.run(pool, fn -> :ok end, []) == :ok
  end

  test "pool shutdown terminates admitted and queued work", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 1)
    active = blocked(tasks, pool, :active)
    assert_receive {:started, :active, worker}
    worker_ref = Process.monitor(worker)
    waiting = blocked(tasks, pool, :waiting)
    await_queued(pool, 1)
    stop_supervised!(ProcessingPool)
    assert Task.await(active) == {:error, {:processing, :unavailable}}
    assert Task.await(waiting) == {:error, {:processing, :unavailable}}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    refute_received {:started, :waiting, _}
  end

  describe "retry_after/1" do
    test "answers without waiting for the pool" do
      pool = start_supervised!({ProcessingPool, max_concurrency: 1, queue_timeout: 2_500})
      :sys.suspend(pool)

      try do
        assert ProcessingPool.retry_after(pool) == 3
      after
        :sys.resume(pool)
      end
    end

    test "has no value once the pool has stopped" do
      pool = start_supervised!({ProcessingPool, max_concurrency: 1})
      stop_supervised!(ProcessingPool)

      assert ProcessingPool.retry_after(pool) == nil
    end
  end

  describe "continuations" do
    # An overlapped request's encode, which asks again for the turn its
    # decode held, with that turn's processing deadline.
    defp continuation(deadline_ms), do: [processing_continuation: now() + deadline_ms]

    defp now, do: System.monotonic_time(:millisecond)

    test "within_turn returns the turn's processing deadline", %{tasks: _tasks} do
      pool = pool(max_concurrency: 1, processing_timeout: 5_000)
      before = now()

      assert {:ok, :done, deadline} =
               ProcessingPool.within_turn(pool, self(), self(), [], fn -> :done end)

      assert deadline >= before + 5_000 and deadline <= now() + 5_000
    end

    test "a continuation is admitted before earlier waiters", %{tasks: tasks} do
      pool = pool(max_concurrency: 1)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      waiting = blocked(tasks, pool, :waiting)
      await_queued(pool, 1)
      resumed = blocked(tasks, pool, :resumed, :normal, continuation(5_000))
      await_queued(pool, 2)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :resumed, worker2}
      refute_received {:started, :waiting, _}
      send(worker2, :continue)
      assert Task.await(resumed) == :ok
      assert_receive {:started, :waiting, worker3}
      send(worker3, :continue)
      assert Task.await(waiting) == :ok
    end

    test "a full queue neither rejects a continuation nor drops a low waiter for it", %{
      tasks: tasks
    } do
      pool = pool(max_concurrency: 1, max_queue: 1)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      low = blocked(tasks, pool, :low, :low)
      await_queued(pool, 1)
      resumed = blocked(tasks, pool, :resumed, :normal, continuation(5_000))
      await_queued(pool, 2)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :resumed, worker2}
      send(worker2, :continue)
      assert Task.await(resumed) == :ok
      assert_receive {:started, :low, worker3}
      send(worker3, :continue)
      assert Task.await(low) == :ok
    end

    test "continuations are admitted in the order they arrive", %{tasks: tasks} do
      pool = pool(max_concurrency: 1)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      earlier = blocked(tasks, pool, :earlier, :normal, continuation(5_000))
      await_queued(pool, 1)
      later = blocked(tasks, pool, :later, :normal, continuation(5_000))
      await_queued(pool, 2)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :earlier, worker2}
      refute_received {:started, :later, _}
      send(worker2, :continue)
      assert Task.await(earlier) == :ok
      assert_receive {:started, :later, worker3}
      send(worker3, :continue)
      assert Task.await(later) == :ok
    end

    test "waiting continuations don't count toward max_queue", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, max_queue: 1)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      resumed = blocked(tasks, pool, :resumed, :normal, continuation(5_000))
      await_queued(pool, 1)
      waiting = blocked(tasks, pool, :waiting)
      await_queued(pool, 2)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :resumed, worker2}
      send(worker2, :continue)
      assert Task.await(resumed) == :ok
      assert_receive {:started, :waiting, worker3}
      send(worker3, :continue)
      assert Task.await(waiting) == :ok
    end

    test "a continuation still waiting at its deadline times out", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, queue_timeout: 60_000)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker}
      resumed = blocked(tasks, pool, :resumed, :normal, continuation(60_000))
      await_queued(pool, 1)

      # Fire the queued continuation's deadline instead of waiting for it.
      [{token, %{deadline: deadline}}] =
        for {token, %{phase: :queued} = job} <- :sys.get_state(pool).jobs, do: {token, job}

      send(pool, {:deadline, token, :queued, deadline})
      assert Task.await(resumed) == {:error, {:processing, :timeout}}
      assert_receive {:stop, %{result: :timeout}}

      send(worker, :continue)
      assert Task.await(first) == :ok
    end

    test "an admitted continuation is cut off at its deadline", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, processing_timeout: 60_000)
      job = blocked(tasks, pool, :resumed, :normal, continuation(60_000))
      assert_receive {:started, :resumed, worker}

      # Its deadline is the one it brought, not processing_timeout from now.
      [{token, %{phase: :active, deadline: deadline}}] = Map.to_list(:sys.get_state(pool).jobs)
      assert deadline <= now() + 60_000
      send(pool, {:deadline, token, :active, deadline})
      assert Task.await(job) == {:error, {:processing, :timeout}}

      ref = Process.monitor(worker)
      send(worker, :continue)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}
    end

    test "a continuation whose deadline has passed fails at once" do
      pool = pool(max_concurrency: 1)

      assert ProcessingPool.run(pool, fn -> flunk() end, continuation(-1)) ==
               {:error, {:processing, :timeout}}
    end

    test "admission marks a continuation", %{tasks: tasks} do
      pool = pool(max_concurrency: 1)
      job = blocked(tasks, pool, :resumed, :normal, continuation(5_000))
      assert_receive {:start, %{continuation: true}}
      assert_receive {:started, :resumed, worker}
      send(worker, :continue)
      assert Task.await(job) == :ok
    end
  end

  describe "low priority" do
    test "admits a waiting normal request before an earlier low one", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, max_queue: 2)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      low = blocked(tasks, pool, :low, :low)
      await_queued(pool, 1)
      normal = blocked(tasks, pool, :normal)
      await_queued(pool, 2)
      assert %{queued: 2, low_queued: 1} = ProcessingPool.stats(pool)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :normal, worker2}
      refute_received {:started, :low, _}
      send(worker2, :continue)
      assert Task.await(normal) == :ok
      assert_receive {:started, :low, worker3}
      send(worker3, :continue)
      assert Task.await(low) == :ok
    end

    test "holds at most low_priority_max_concurrency slots", %{tasks: tasks} do
      pool = pool(max_concurrency: 2, low_priority_max_concurrency: 1, max_queue: 1)
      first = blocked(tasks, pool, :first, :low)
      assert_receive {:started, :first, worker1}
      second = blocked(tasks, pool, :second, :low)
      await_queued(pool, 1)
      assert %{active: 1, low_active: 1, queued: 1, low_queued: 1} = ProcessingPool.stats(pool)

      normal = blocked(tasks, pool, :normal)
      assert_receive {:started, :normal, worker2}
      send(worker2, :continue)
      assert Task.await(normal) == :ok
      refute_received {:started, :second, _}

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :second, worker3}
      send(worker3, :continue)
      assert Task.await(second) == :ok
    end

    test "low_priority_max_concurrency defaults to half of max_concurrency", %{tasks: tasks} do
      pool = pool(max_concurrency: 4)
      first = blocked(tasks, pool, :first, :low)
      assert_receive {:started, :first, worker1}
      second = blocked(tasks, pool, :second, :low)
      assert_receive {:started, :second, worker2}
      third = blocked(tasks, pool, :third, :low)
      assert_receive {:start, %{active: 2, queued: 0, priority: :low}}
      assert %{active: 2, low_active: 2, low_queued: 1} = ProcessingPool.stats(pool)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :third, worker3}

      for {task, worker} <- [{second, worker2}, {third, worker3}] do
        send(worker, :continue)
        assert Task.await(task) == :ok
      end
    end

    test "a normal request finding the queue full pushes out the newest low waiter", %{
      tasks: tasks
    } do
      pool = pool(max_concurrency: 1, max_queue: 2)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker1}
      older = blocked(tasks, pool, :older, :low)
      await_queued(pool, 1)
      newer = blocked(tasks, pool, :newer, :low)
      await_queued(pool, 2)

      normal = blocked(tasks, pool, :normal)
      assert Task.await(newer) == {:error, {:processing, :overloaded}}
      assert_receive {:stop, %{result: :overloaded, priority: :low}}
      assert %{queued: 2, low_queued: 1} = ProcessingPool.stats(pool)

      send(worker1, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :normal, worker2}
      send(worker2, :continue)
      assert Task.await(normal) == :ok
      assert_receive {:started, :older, worker3}
      send(worker3, :continue)
      assert Task.await(older) == :ok
      refute_received {:started, :newer, _}
    end

    test "a low request finding the queue full fails", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, max_queue: 1)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker}
      waiting = blocked(tasks, pool, :waiting)
      await_queued(pool, 1)

      assert {:error, {:processing, :overloaded}} =
               ProcessingPool.run(pool, fn -> flunk() end, processing_priority: :low)

      send(worker, :continue)
      assert Task.await(first) == :ok
      assert_receive {:started, :waiting, worker2}
      send(worker2, :continue)
      assert Task.await(waiting) == :ok
    end

    test "a low waiter times out while normal work holds the slots", %{tasks: tasks} do
      pool = pool(max_concurrency: 1, max_queue: 1, queue_timeout: 50)
      first = blocked(tasks, pool, :first)
      assert_receive {:started, :first, worker}

      assert {:error, {:processing, :queue_timeout}} =
               ProcessingPool.run(pool, fn -> flunk() end, processing_priority: :low)

      assert %{queued: 0, low_queued: 0} = ProcessingPool.stats(pool)
      send(worker, :continue)
      assert Task.await(first) == :ok
    end

    test "admission spans carry the request's priority", %{tasks: tasks} do
      pool = pool(max_concurrency: 1)
      low = blocked(tasks, pool, :low, :low)
      assert_receive {:start, %{priority: :low}}
      assert_receive {:started, :low, worker}
      assert_receive {:stop, %{result: :admitted, priority: :low}}
      send(worker, :continue)
      assert Task.await(low) == :ok

      assert ProcessingPool.run(pool, fn -> :ok end,
               telemetry_prefix: Process.get(:pool_telemetry)
             ) ==
               :ok

      assert_receive {:start, %{priority: :normal}}
    end
  end

  test "validates host pool options" do
    for opts <- [
          [max_concurrency: 0],
          [max_concurrency: 1, max_queue: -1],
          [max_concurrency: 1, queue_timeout: :infinity],
          [max_concurrency: 1, processing_timeout: 0],
          [max_concurrency: 1, low_priority_max_concurrency: 0],
          [max_concurrency: 1, unknown: true]
        ] do
      assert_raise ArgumentError, fn -> ProcessingPool.start_link(opts) end
    end
  end

  defp pool(opts), do: start_supervised!({ProcessingPool, opts})

  defp blocked(tasks, pool, label, priority \\ :normal, extra \\ []) do
    test = self()

    config =
      [telemetry_prefix: Process.get(:pool_telemetry), processing_priority: priority] ++ extra

    Task.Supervisor.async_nolink(tasks, fn ->
      ProcessingPool.run(
        pool,
        fn ->
          send(test, {:started, label, self()})

          receive do
            :continue -> :ok
          end
        end,
        config
      )
    end)
  end

  # Synchronize admission through the pool's observable queue count.
  defp await_queued(pool, count) do
    previous = count - 1
    assert_receive {:start, %{active: 1, queued: ^previous}}
    assert %{queued: ^count} = ProcessingPool.stats(pool)
  end
end

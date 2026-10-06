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

  test "validates host pool options" do
    for opts <- [
          [max_concurrency: 0],
          [max_concurrency: 1, max_queue: -1],
          [max_concurrency: 1, queue_timeout: :infinity],
          [max_concurrency: 1, processing_timeout: 0],
          [max_concurrency: 1, unknown: true]
        ] do
      assert_raise ArgumentError, fn -> ProcessingPool.start_link(opts) end
    end
  end

  defp pool(opts), do: start_supervised!({ProcessingPool, opts})

  defp blocked(tasks, pool, label) do
    test = self()
    config = [telemetry_prefix: Process.get(:pool_telemetry)]

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

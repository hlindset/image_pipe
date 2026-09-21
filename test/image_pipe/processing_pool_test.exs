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
    pool = pool(max_concurrency: 1)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker}
    assert {:error, {:processing, :overloaded}} = ProcessingPool.run(pool, fn -> flunk() end)
    send(worker, :continue)
    assert Task.await(first) == :ok
    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
  end

  test "admits queued jobs in FIFO order", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 2)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker1}
    second = blocked(tasks, pool, :second)
    await_queued(pool, 1)
    third = blocked(tasks, pool, :third)
    await_queued(pool, 2)
    assert {:error, {:processing, :overloaded}} = ProcessingPool.run(pool, fn -> flunk() end)

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
    pool = pool(max_concurrency: 1, max_queue: 1, queue_timeout: 30)
    first = blocked(tasks, pool, :first)
    assert_receive {:started, :first, worker}
    assert {:error, {:processing, :queue_timeout}} = ProcessingPool.run(pool, fn -> flunk() end)
    send(worker, :continue)
    assert Task.await(first) == :ok
    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
  end

  test "processing deadline stops a worker and recovers its slot", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, processing_timeout: 40)
    job = blocked(tasks, pool, :timed)
    assert_receive {:started, :timed, worker}
    ref = Process.monitor(worker)
    assert Task.await(job) == {:error, {:processing, :timeout}}
    assert_receive {:DOWN, ^ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
  end

  test "owner death cancels active and queued work", %{tasks: tasks} do
    pool = pool(max_concurrency: 1, max_queue: 1)
    active = blocked(tasks, pool, :active)
    assert_receive {:started, :active, worker}
    waiting = blocked(tasks, pool, :waiting)
    await_queued(pool, 1)
    worker_ref = Process.monitor(worker)
    Task.shutdown(waiting, :brutal_kill)
    assert_receive {:stop, %{result: :cancelled}}
    Task.shutdown(active, :brutal_kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
    refute_received {:started, :waiting, _}
  end

  test "callback failures release capacity and retain their exception" do
    pool = pool(max_concurrency: 1)

    assert_raise RuntimeError, "broken", fn ->
      ProcessingPool.run(pool, fn -> raise "broken" end)
    end

    assert ProcessingPool.run(pool, fn -> {:error, {:decode, :bad}} end) ==
             {:error, {:decode, :bad}}

    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
  end

  test "worker death releases admission even without callback cleanup", %{tasks: tasks} do
    pool = pool(max_concurrency: 1)
    job = blocked(tasks, pool, :dying)
    assert_receive {:started, :dying, worker}
    Process.exit(worker, :kill)
    assert Task.await(job) == {:error, {:processing, :worker_down}}
    assert ProcessingPool.run(pool, fn -> :ok end) == :ok
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

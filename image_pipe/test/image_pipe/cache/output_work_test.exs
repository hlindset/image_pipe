defmodule ImagePipe.Cache.OutputWorkTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.OutputWork

  setup %{test: test} do
    tasks = start_supervised!(Task.Supervisor)
    opts = [telemetry_prefix: [__MODULE__, test]]
    handler = make_ref()

    :telemetry.attach(
      handler,
      opts[:telemetry_prefix] ++ [:cache, :coordination],
      &__MODULE__.event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{tasks: tasks, opts: opts, cache: {__MODULE__, scope: make_ref()}}
  end

  def event(_event, _measurements, metadata, test), do: send(test, metadata.result)

  test "completion wakes all followers and expired waits bypass without disturbing the leader",
       context do
    {:leader, lease} = join(context)
    expired = async(context, fn -> join(context, 10) end)
    assert_receive :waiting
    assert Task.await(expired) == :bypass
    followers = for _ <- 1..3, do: async(context, fn -> join(context) end)
    for _ <- 1..3, do: assert_receive(:waiting)
    OutputWork.complete(lease, :ready)
    for follower <- followers, do: assert(Task.await(follower) == :ready)
    {:leader, next} = join(context)
    OutputWork.complete(next, :ready)
  end

  test "leader death promotes one surviving waiter and stale completion cannot release it",
       context do
    test = self()

    owner =
      async(context, fn ->
        {:leader, lease} = join(context)
        send(test, {:lease, lease})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:lease, old}
    dead = async(context, fn -> join(context) end)
    assert_receive :waiting
    Task.shutdown(dead, :brutal_kill)
    _ = :sys.get_state(OutputWork)

    promoted =
      async(context, fn ->
        {:leader, lease} = join(context)
        send(test, {:promoted, lease})
        receive do: (:finish -> OutputWork.complete(lease, :ready))
      end)

    assert_receive :waiting
    follower = async(context, fn -> join(context) end)
    assert_receive :waiting
    Task.shutdown(owner, :brutal_kill)
    assert_receive {:promoted, _lease}
    OutputWork.complete(old, :ready)
    assert Task.yield(follower, 0) == nil
    send(promoted.pid, :finish)
    Task.await(promoted)
    assert Task.await(follower) == :ready
  end

  test "capacity saturation bypasses coordination", context do
    leases =
      for key <- 1..64 do
        assert {:leader, lease} =
                 OutputWork.join(context.cache, Integer.to_string(key), context.opts)

        lease
      end

    assert :bypass = OutputWork.join(context.cache, "overflow", context.opts)
    Enum.each(leases, &OutputWork.complete(&1, :ready))
  end

  test "coordinator restart releases waiters and old leases cannot affect new work", context do
    {:leader, old} = join(context)
    follower = async(context, fn -> join(context) end)
    assert_receive :waiting
    on_exit(fn -> Supervisor.restart_child(ImagePipe.Supervisor, OutputWork) end)
    :ok = Supervisor.terminate_child(ImagePipe.Supervisor, OutputWork)
    assert Task.await(follower) == :bypass
    assert join(context) == :bypass
    {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, OutputWork)
    {:leader, lease} = join(context)
    OutputWork.complete(old, :ready)
    follower = async(context, fn -> join(context) end)
    assert_receive :waiting
    OutputWork.complete(lease, :ready)
    assert Task.await(follower) == :ready
  end

  defp join(context, timeout \\ 60_000),
    do: OutputWork.join(context.cache, "output", context.opts, timeout)

  defp async(context, fun), do: Task.Supervisor.async_nolink(context.tasks, fun)
end

defmodule ImagePipe.Cache.WorkTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Cache.Work

  test "an unavailable coordinator falls back without failing the request" do
    :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
    on_exit(fn -> Supervisor.restart_child(ImagePipe.Supervisor, Work) end)

    assert :served =
             Work.run(make_ref(), fn coordinated?, outcome ->
               refute coordinated?
               assert outcome == :busy
               :served
             end)

    assert :busy = Work.refresh(make_ref(), fn -> flunk("unavailable") end)
  end

  test "coordinator failure during work does not replace its result" do
    on_exit(fn -> Supervisor.restart_child(ImagePipe.Supervisor, Work) end)

    assert :served =
             Work.run(make_ref(), fn lease, _outcome ->
               assert Work.current?(lease)
               :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
               {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, Work)
               refute Work.current?(lease)
               :served
             end)
  end

  test "a waiter stops waiting after its wait limit and leaves the lock usable" do
    key = make_ref()
    parent = self()

    leader =
      Task.async(fn ->
        Work.run(key, fn _lease, _outcome ->
          send(parent, :locked)

          receive do
            :finish -> :led
          end
        end)
      end)

    assert_receive :locked

    assert Work.run(key, fn _lease, _outcome -> flunk("timed-out waiter ran") end, wait: 50) ==
             :timeout

    send(leader.pid, :finish)
    assert Task.await(leader) == :led
    assert Work.run(key, fn lease, _outcome -> is_reference(lease) end, wait: 50)
  end

  test "owner cancellation releases the key for waiting work" do
    supervisor = start_supervised!(Task.Supervisor)
    key = make_ref()
    parent = self()

    leader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, outcome ->
          assert outcome == :acquired
          assert Work.current?(lease)
          send(parent, :locked)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :locked

    follower =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, outcome ->
          assert outcome == :coalesced
          assert Work.current?(lease)
          :released
        end)
      end)

    await_waiter(key, follower)
    Task.shutdown(leader, :brutal_kill)
    assert Task.await(follower) == :released
  end

  test "publication stays ordered across a coordinator restart" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    key = make_ref()

    old =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, _outcome ->
          Work.publish(key, lease, fn ->
            send(parent, :old_publication)

            receive do
              :continue -> send(parent, {:published, 1})
            end
          end)
        end)
      end)

    assert_receive :old_publication
    :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
    {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, Work)

    newer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, _outcome ->
          send(parent, :new_lease)
          Work.publish(key, lease, fn -> send(parent, {:published, 2}) end)
        end)
      end)

    assert_receive :new_lease
    refute_received {:published, _}
    send(old.pid, :continue)
    Task.await(old)
    Task.await(newer)
    assert_receive {:published, first}
    assert first == 1
    assert_receive {:published, second}
    assert second == 2
  end

  # The follower's lock request reaches Work some time after it starts, so
  # the leader goes away only once Work holds the follower as a waiter.
  defp await_waiter(key, follower) do
    monitor = Process.monitor(follower.pid)

    try do
      await_waiter(key, monitor, System.monotonic_time(:millisecond) + 5_000)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_waiter(key, monitor, deadline) do
    locks = :sys.get_state(Work).locks

    receive do
      {:DOWN, ^monitor, :process, _pid, reason} ->
        flunk("follower exited before queuing: #{inspect(reason)}")
    after
      0 ->
        cond do
          match?(%{^key => %{waiters: [_ | _]}}, locks) ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("follower never queued for the key; Work locks: #{inspect(locks)}")

          true ->
            await_waiter(key, monitor, deadline)
        end
    end
  end
end

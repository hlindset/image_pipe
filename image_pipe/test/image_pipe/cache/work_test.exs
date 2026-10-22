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
             Work.run(
               make_ref(),
               fn lease, _outcome ->
                 assert Work.current?(lease)
                 :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
                 {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, Work)
                 refute Work.current?(lease)
                 assert Work.complete(lease, :obsolete) == :ok
                 :served
               end,
               share: make_ref()
             )
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

  test "a lock granted after its waiter stopped waiting is released" do
    key = make_ref()
    parent = self()
    work = Process.whereis(Work)

    leader =
      Task.async(fn ->
        Work.run(key, fn _lease, _outcome ->
          send(parent, :locked)
          receive(do: (:finish -> :led))
        end)
      end)

    assert_receive :locked

    :erlang.trace(work, true, [:receive])

    on_exit(fn ->
      :erlang.trace(work, false, [:receive])
      :sys.resume(work)
    end)

    # The waiter stays alive afterwards, so its monitor can't free the lock.
    waiter =
      spawn_link(fn ->
        send(parent, {:waited, Work.run(key, fn _lease, _outcome -> :ran end, wait: 200)})
        receive(do: (:stop -> :ok))
      end)

    assert_receive {:trace, ^work, :receive, {:"$gen_call", {^waiter, _tag}, {:lock, ^key, _}}}
    _state = :sys.get_state(work)

    # The leader's unlock grants the lock to the waiter, but the coordinator
    # handles it only after the waiter has stopped waiting and asked to
    # cancel.
    :sys.suspend(work)
    send(leader.pid, :finish)
    assert_receive {:trace, ^work, :receive, {:"$gen_call", _from, {:unlock, _ref}}}
    assert_receive {:trace, ^work, :receive, {:"$gen_call", _from, {:cancel_wait, ^key}}}, 1_000
    :erlang.trace(work, false, [:receive])
    :sys.resume(work)

    assert Task.await(leader) == :led
    assert_receive {:waited, :timeout}
    assert Work.run(key, fn _lease, outcome -> outcome end, wait: 50) == :acquired

    send(waiter, :stop)
  end

  test "a waiter's cancellation releases a lock granted to it that it never received" do
    key = make_ref()
    parent = self()

    leader =
      Task.async(fn ->
        Work.run(key, fn _lease, _outcome ->
          send(parent, :locked)
          receive(do: (:finish -> :led))
        end)
      end)

    assert_receive :locked

    # As when the waiter's cancel call timed out and dropped the grant: the
    # waiter queues for the lock, is granted it, then cancels without
    # reading the grant.
    waiter =
      spawn_link(fn ->
        _request = :gen_server.send_request(Work, {:lock, key, nil})
        send(parent, :queued)

        receive(
          do: (:cancel -> send(parent, {:cancelled, GenServer.call(Work, {:cancel_wait, key})}))
        )

        receive(do: (:stop -> :ok))
      end)

    assert_receive :queued
    _state = :sys.get_state(Work)
    send(leader.pid, :finish)
    assert Task.await(leader) == :led

    send(waiter, :cancel)
    assert_receive {:cancelled, :ok}
    assert Work.run(key, fn _lease, outcome -> outcome end, wait: 50) == :acquired

    send(waiter, :stop)
  end

  test "owner cancellation releases the key for waiting work" do
    supervisor = start_supervised!(Task.Supervisor)
    key = make_ref()
    parent = self()
    context = make_ref()

    leader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(
          key,
          fn lease, outcome ->
            assert outcome == :acquired
            assert Work.current?(lease)
            send(parent, :locked)

            receive do
              :finish -> :ok
            end
          end,
          share: context
        )
      end)

    assert_receive :locked

    follower =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(
          key,
          fn lease, outcome ->
            assert outcome == :coalesced
            assert Work.current?(lease)
            :released
          end,
          share: context
        )
      end)

    await_waiter(key, follower)
    Task.shutdown(leader, :brutal_kill)
    assert Task.await(follower) == :released
  end

  test "completion shares only with the matching queued cohort" do
    supervisor = start_supervised!(Task.Supervisor)
    key = make_ref()
    context = make_ref()
    parent = self()

    leader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(
          key,
          fn lease, :acquired ->
            send(parent, :locked)

            receive do
              :finish ->
                assert Work.complete(lease, :validated) == :ok
                refute Work.current?(lease)
                :leader_result
            end
          end,
          share: context
        )
      end)

    assert_receive :locked

    different =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, :coalesced ->
          assert Work.current?(lease)
          :different_result
        end)
      end)

    followers =
      for _ <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Work.run(key, fn _, _ -> flunk("shared waiter repeated the work") end, share: context)
        end)
      end

    for task <- [different | followers], do: await_waiter(key, task)
    send(leader.pid, :finish)
    assert Task.await(leader) == :leader_result
    assert Task.await(different) == :different_result
    for task <- followers, do: assert(Task.await(task) == :validated)

    assert Work.run(key, fn _, :acquired -> :new_work end, share: context) == :new_work
  end

  test "a timed-out cohort member is not completed later" do
    supervisor = start_supervised!(Task.Supervisor)
    key = make_ref()
    context = make_ref()
    parent = self()

    leader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(
          key,
          fn lease, _ ->
            send(parent, :locked)

            receive do
              :finish -> Work.complete(lease, :validated)
            end
          end,
          share: context
        )
      end)

    assert_receive :locked

    assert Work.run(key, fn _, _ -> flunk("timed-out waiter ran") end,
             share: context,
             wait: 20
           ) == :timeout

    send(leader.pid, :finish)
    assert Task.await(leader) == :ok
    assert Work.run(key, fn _, _ -> :new_work end, share: context) == :new_work
  end

  test "a publication without a lease doesn't wait for a leased one" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    key = make_ref()

    leased =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease, _outcome ->
          Work.publish(key, lease, fn ->
            send(parent, :locked)

            receive do
              :continue -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked
    assert Work.publish(key, nil, fn -> :unleased end) == {:ok, :unleased}
    send(leased.pid, :continue)
    assert Task.await(leased) == {:ok, :ok}
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
      await_waiter(key, follower.pid, monitor, System.monotonic_time(:millisecond) + 5_000)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_waiter(key, pid, monitor, deadline) do
    locks = :sys.get_state(Work).locks

    waiters =
      case Map.get(locks, key) do
        nil -> []
        lock -> lock.waiters
      end

    receive do
      {:DOWN, ^monitor, :process, _pid, reason} ->
        flunk("follower exited before queuing: #{inspect(reason)}")
    after
      0 ->
        cond do
          Enum.any?(waiters, fn waiter -> elem(elem(waiter, 1), 0) == pid end) ->
            :ok

          System.monotonic_time(:millisecond) > deadline ->
            flunk("follower never queued for the key; Work locks: #{inspect(locks)}")

          true ->
            await_waiter(key, pid, monitor, deadline)
        end
    end
  end
end

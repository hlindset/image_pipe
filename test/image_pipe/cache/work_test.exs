defmodule ImagePipe.Cache.WorkTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Cache.Work

  test "an unavailable coordinator falls back without failing the request" do
    :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
    on_exit(fn -> Supervisor.restart_child(ImagePipe.Supervisor, Work) end)

    assert :served =
             Work.run(make_ref(), fn coordinated? ->
               refute coordinated?
               :served
             end)

    assert :busy = Work.refresh(make_ref(), fn -> flunk("unavailable") end)
  end

  test "coordinator failure during work does not replace its result" do
    on_exit(fn -> Supervisor.restart_child(ImagePipe.Supervisor, Work) end)

    assert :served =
             Work.run(make_ref(), fn lease ->
               assert Work.current?(lease)
               :ok = Supervisor.terminate_child(ImagePipe.Supervisor, Work)
               {:ok, _pid} = Supervisor.restart_child(ImagePipe.Supervisor, Work)
               refute Work.current?(lease)
               :served
             end)
  end

  test "owner cancellation releases the key for waiting work" do
    supervisor = start_supervised!(Task.Supervisor)
    key = make_ref()
    parent = self()

    leader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease ->
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
        Work.run(key, fn lease ->
          assert Work.current?(lease)
          :released
        end)
      end)

    Task.shutdown(leader, :brutal_kill)
    assert Task.await(follower) == :released
  end

  test "publication stays ordered across a coordinator restart" do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()
    key = make_ref()

    old =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Work.run(key, fn lease ->
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
        Work.run(key, fn lease ->
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
end

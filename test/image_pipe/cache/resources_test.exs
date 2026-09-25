defmodule ImagePipe.Cache.ResourcesTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Resources

  setup do
    path = Input.temporary_path(System.tmp_dir!())
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "explicit release cleans a file after the tracker restarts", %{path: path} do
    lease = Resources.track(path)
    File.write!(path, "source bytes")
    restart_tracker()

    assert :ok = Resources.release(lease)
    refute File.exists?(path)
  end

  test "owner death cleans its file after the tracker restarts", %{path: path} do
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        Resources.track(path)
        File.write!(path, "source bytes")
        send(parent, :tracked)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :tracked
    restart_tracker()
    assert File.read!(path) == "source bytes"
    Task.shutdown(owner, :brutal_kill)
    _ = :sys.get_state(Resources)
    refute File.exists?(path)
  end

  test "explicit release cleans a file while the tracker is unavailable", %{path: path} do
    lease = Resources.track(path)
    File.write!(path, "source bytes")
    supervisor = tracker_supervisor()
    assert :ok = Supervisor.terminate_child(supervisor, Resources)

    try do
      assert :ok = Resources.release(lease)
      refute File.exists?(path)
    after
      assert {:ok, _pid} = Supervisor.restart_child(supervisor, Resources)
    end
  end

  test "completed reader directories are removed after tracker restart", %{path: path} do
    File.mkdir!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    File.write!(Path.join(path, "body"), "reader bytes")
    lease = Resources.track_directory(path, 1_000)
    restart_tracker()
    assert :ok = Resources.release(lease)
    refute File.exists?(path)
  end

  test "registration is bounded and release needs no tracker message", %{path: path} do
    tracker = Process.whereis(Resources)
    :ok = :sys.suspend(tracker)

    try do
      handles = for index <- 1..1_100, do: Resources.track("#{path}-#{index}")
      registered = Enum.reject(handles, &(&1 == :unavailable))
      assert length(registered) <= 1_024
      assert :unavailable in handles
      Enum.each(registered, &Resources.release/1)

      replacement = Resources.track(path)
      refute replacement == :unavailable
      File.write!(path, "replacement")
      assert :ok = Resources.release(replacement)
      refute File.exists?(path)

      assert {:messages, messages} = Process.info(tracker, :messages)
      refute Enum.any?(messages, &match?({:"$gen_call", _, _}, &1))
    after
      :ok = :sys.resume(tracker)
    end
  end

  test "released handles cannot unregister a reused slot", %{path: path} do
    first = Resources.track(path)
    assert :ok = Resources.release(first)
    second_path = path <> "-second"
    on_exit(fn -> File.rm(second_path) end)
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        refute Resources.track(second_path) == :unavailable
        File.write!(second_path, "new resource")
        send(parent, :tracked)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :tracked
    assert :ok = Resources.release(first)
    restart_tracker()
    assert File.read!(second_path) == "new resource"
    Task.shutdown(owner, :brutal_kill)
    _ = :sys.get_state(Resources)
    refute File.exists?(second_path)
  end

  test "owner death before the first monitor pass still reclaims the resource", %{path: path} do
    tasks = start_supervised!(Task.Supervisor)
    tracker = Process.whereis(Resources)
    :erlang.trace(tracker, true, [:receive])
    :ok = :sys.suspend(tracker)

    owner_pid =
      try do
        owner =
          Task.Supervisor.async_nolink(tasks, fn ->
            refute Resources.track(path) == :unavailable
            File.write!(path, "abandoned before monitoring")
          end)

        assert :ok = Task.await(owner)
        assert File.exists?(path)
        owner.pid
      after
        :ok = :sys.resume(tracker)
      end

    send(tracker, :reconcile)
    assert_receive {:trace, ^tracker, :receive, {:DOWN, _, :process, ^owner_pid, _}}
    _ = :sys.get_state(tracker)
    refute File.exists?(path)
  end

  test "failed local cleanup retains ownership for a later retry", %{path: path} do
    File.mkdir!(path)
    body = Path.join(path, "body")
    File.write!(body, "retained until removable")

    on_exit(fn ->
      File.chmod(path, 0o700)
      File.rm_rf(path)
    end)

    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        handle = Resources.track(body)
        send(parent, {:tracked, handle})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:tracked, handle}
    send(Resources, :reconcile)
    _ = :sys.get_state(Resources)
    File.chmod!(path, 0o500)
    assert {:error, :eacces} = Resources.release(handle)
    Task.shutdown(owner, :brutal_kill)
    _ = :sys.get_state(Resources)
    assert File.exists?(body)

    File.chmod!(path, 0o700)
    send(Resources, :reconcile)
    _ = :sys.get_state(Resources)
    refute File.exists?(body)
  end

  defp restart_tracker do
    supervisor = tracker_supervisor()
    assert :ok = Supervisor.terminate_child(supervisor, Resources)
    assert {:ok, _pid} = Supervisor.restart_child(supervisor, Resources)
  end

  defp tracker_supervisor do
    {:dictionary, dictionary} = Process.info(Process.whereis(Resources), :dictionary)
    [supervisor | _] = Keyword.fetch!(dictionary, :"$ancestors")
    supervisor
  end
end

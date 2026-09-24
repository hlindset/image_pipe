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

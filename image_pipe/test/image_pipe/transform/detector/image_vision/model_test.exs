defmodule ImagePipe.Transform.Detector.ImageVision.ModelTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Detector.ImageVision.Model

  # Runs `Model.ensure_loaded/2` in a new process whose probe reports when it
  # starts and then waits for `:release` before returning `result`.
  defp start_call(key, result) do
    test = self()

    spawn_link(fn ->
      returned =
        Model.ensure_loaded(key, fn ->
          send(test, {:running, self()})

          receive do
            :release -> result
          end
        end)

      send(test, {:returned, self(), returned})
    end)
  end

  defp assert_running(pid), do: assert_receive({:running, ^pid})

  defp release(pid) do
    send(pid, :release)
    assert_receive {:returned, ^pid, _returned}
  end

  # Waits until `pid` monitors the lock, so it is waiting on the running probe.
  defp await_waiting(key, pid) do
    lock = Process.whereis(Module.concat(key, FirstLoad))
    {:monitored_by, monitors} = Process.info(lock, :monitored_by)

    unless pid in monitors do
      :erlang.yield()
      await_waiting(key, pid)
    end
  end

  test "callers wait while the first probe runs, then return without probing" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:ok, []})
    assert_running(first)

    second = start_call(key, {:ok, []})
    await_waiting(key, second)

    release(first)
    assert_receive {:returned, ^second, :ok}
    refute_received {:running, ^second}
  end

  test "callers waiting on a failed probe get its error, and a later caller probes" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:error, :boom})
    assert_running(first)

    second = start_call(key, {:ok, []})
    await_waiting(key, second)
    release(first)
    assert_receive {:returned, ^second, {:error, :boom}}
    refute_received {:running, ^second}

    third = start_call(key, {:ok, []})
    assert_running(third)
    release(third)
  end

  test "a caller that dies mid-probe lets the next caller probe" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    Process.flag(:trap_exit, true)
    first = start_call(key, {:ok, []})
    assert_running(first)

    second = start_call(key, {:ok, []})
    await_waiting(key, second)
    Process.exit(first, :kill)
    assert_running(second)
    release(second)
  end

  test "calls after a successful probe don't probe again" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:ok, []})
    assert_running(first)
    release(first)

    second = start_call(key, {:ok, []})
    assert_receive {:returned, ^second, :ok}
    refute_received {:running, ^second}
  end
end

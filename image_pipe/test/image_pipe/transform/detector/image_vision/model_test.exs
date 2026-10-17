defmodule ImagePipe.Transform.Detector.ImageVision.ModelTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Detector.ImageVision.Model

  # Runs `Model.first_load/2` in a new process whose fun reports when it starts
  # and then waits for `:release` before returning `result`.
  defp start_call(key, result) do
    test = self()

    spawn_link(fn ->
      Model.first_load(key, fn ->
        send(test, {:running, self()})

        receive do
          :release -> result
        end
      end)

      send(test, {:returned, self()})
    end)
  end

  defp assert_running(pid), do: assert_receive({:running, ^pid})

  defp release(pid) do
    send(pid, :release)
    assert_receive {:returned, ^pid}
  end

  test "callers wait while the first load runs" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:ok, []})
    assert_running(first)

    second = start_call(key, {:ok, []})
    refute_receive {:running, ^second}, 200

    release(first)
    assert_running(second)
    release(second)
  end

  test "a failed load lets the next caller load" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:error, :boom})
    assert_running(first)

    second = start_call(key, {:ok, []})
    release(first)
    assert_running(second)

    third = start_call(key, {:ok, []})
    refute_receive {:running, ^third}, 200

    release(second)
    assert_running(third)
    release(third)
  end

  test "a caller that dies mid-load lets the next caller load" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    Process.flag(:trap_exit, true)
    first = start_call(key, {:ok, []})
    assert_running(first)

    second = start_call(key, {:ok, []})
    Process.exit(first, :kill)
    assert_running(second)
    release(second)
  end

  test "calls after a successful load run concurrently" do
    key = :"adapter_#{System.unique_integer([:positive])}"
    first = start_call(key, {:ok, []})
    assert_running(first)
    release(first)

    second = start_call(key, {:ok, []})
    third = start_call(key, {:ok, []})
    assert_running(second)
    assert_running(third)
    release(second)
    release(third)
  end
end

defmodule ImagePipe.Cache.SharedFileSystem.IOTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.IO.Admission
  alias ImagePipe.Test.SharedIOProbe

  setup ctx do
    pid =
      start_supervised!(
        {CacheIO,
         max_operations: 2,
         max_bytes: 8,
         max_pending: Map.get(ctx, :max_pending, 2),
         max_request_bytes: 256}
      )

    pool = CacheIO.client(pid)
    %{pool: pool}
  end

  test "operations execute in a separate local OS process", %{pool: pool} do
    assert {:ok, pid} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
    refute pid == :os.getpid()
    assert {:ok, :nonode@nohost} = CacheIO.run(pool, {:erlang, :node, []}, 0, 1_000)
  end

  test "timeout retains byte reservation until operation completes", %{pool: pool} do
    assert {:error, :timeout} =
             CacheIO.run(pool, {SharedIOProbe, :wait, [:blocked]}, 8, 50)

    assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 1, 1_000)
    assert {:ok, _} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "timeout also retains operation slots", %{pool: pool} do
    assert {:error, :timeout} = CacheIO.run(pool, {SharedIOProbe, :wait, [:one]}, 0, 50)
    assert {:error, :timeout} = CacheIO.run(pool, {SharedIOProbe, :wait, [:two]}, 0, 50)
    assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "remote failures return errors and release reservations", %{pool: pool} do
    assert {:error, {:operation, :error, :badarg}} =
             CacheIO.run(pool, {:erlang, :error, [:badarg]}, 8, 1_000)

    assert {:ok, _} = CacheIO.run(pool, {:os, :getpid, []}, 8, 1_000)
  end

  test "oversized work is rejected before executing", %{pool: pool} do
    assert {:error, :saturated} =
             CacheIO.run(pool, {:persistent_term, :put, [:not_executed, true]}, 9, 1_000)

    assert {:ok, false} =
             CacheIO.run(pool, {:persistent_term, :get, [:not_executed, false]}, 0, 1_000)
  end

  test "helper death degrades the pool without spawning replacements", %{pool: pool} do
    assert {:error, _} = CacheIO.run(pool, {:erlang, :halt, []}, 0, 1_000)
    assert {:error, :unavailable} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "an ambiguous call exit disables admission even while the helper lives", %{pool: pool} do
    assert {:error, :unavailable} =
             CacheIO.run(pool, {:erlang, :exit, [:lost_control]}, 8, 1_000)

    assert {:error, :unavailable} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "work whose deadline expired in the mailbox never starts", %{pool: pool} do
    :ok = :sys.suspend(pool.pid)

    try do
      assert {:error, :timeout} =
               CacheIO.run(pool, {:persistent_term, :put, [:expired_work, true]}, 0, 10)
    after
      :sys.resume(pool.pid)
    end

    assert {:ok, false} =
             CacheIO.run(pool, {:persistent_term, :get, [:expired_work, false]}, 0, 1_000)
  end

  test "expired calls retain pending capacity until the mailbox consumes them", %{pool: pool} do
    :ok = :sys.suspend(pool.pid)

    try do
      assert {:error, :timeout} = CacheIO.run(pool, {:os, :getpid, []}, 0, 10)
      assert {:error, :timeout} = CacheIO.run(pool, {:os, :getpid, []}, 0, 10)
      assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 0, 10)
      assert {:error, :saturated} = CacheIO.reserve(pool, 0, {File, :rm, ["unused"]}, 10)
    after
      :sys.resume(pool.pid)
    end

    _ = :sys.get_state(pool.pid)
    assert {:ok, _pid} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "oversized request payloads are rejected before enqueueing", %{pool: pool} do
    :ok = :sys.suspend(pool.pid)

    try do
      assert {:error, :saturated} =
               CacheIO.run(pool, {:erlang, :byte_size, [String.duplicate("x", 257)]}, 0, 10)
    after
      :sys.resume(pool.pid)
    end
  end

  @tag max_pending: 1
  test "caller death between admission and enqueueing does not leak a slot", %{pool: pool} do
    tasks = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        request = {:run, {:os, :getpid, []}, 0, System.monotonic_time(:millisecond) + 1_000, nil}
        {:ok, _ticket} = Admission.claim(pool.admission, request)
        send(parent, :admitted)

        receive do
          :enqueue -> :ok
        end
      end)

    assert_receive :admitted
    assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
    Task.shutdown(owner, :brutal_kill)
    await_admission(pool, System.monotonic_time(:millisecond) + 3_000)
  end

  test "caller death keeps the running operation reserved", %{pool: pool} do
    tasks = start_supervised!(Task.Supervisor)

    {:ok, caller} =
      Task.Supervisor.start_child(tasks, fn ->
        CacheIO.run(pool, {SharedIOProbe, :wait, [:orphan]}, 8, 10_000)
      end)

    await_registration(pool, :orphan, System.monotonic_time(:millisecond) + 1_000)
    monitor = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 1, 1_000)
  end

  test "normal completion releases the operation budget", %{pool: pool} do
    tasks = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(tasks, fn ->
        CacheIO.run(pool, {SharedIOProbe, :wait, [:finishing]}, 8, 2_000)
      end)

    await_registration(pool, :finishing, System.monotonic_time(:millisecond) + 1_000)
    assert {:ok, :release} = CacheIO.run(pool, {:erlang, :send, [:finishing, :release]}, 0, 1_000)
    assert {:ok, :released} = Task.await(task)
    assert {:ok, _} = CacheIO.run(pool, {:os, :getpid, []}, 8, 1_000)
  end

  defp await_registration(pool, name, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    case CacheIO.run(pool, {:erlang, :whereis, [name]}, 0, 1_000) do
      {:ok, :undefined} -> await_registration(pool, name, deadline)
      {:ok, pid} when is_pid(pid) -> :ok
    end
  end

  defp await_admission(pool, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    case CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000) do
      {:error, :saturated} ->
        _ = :sys.get_state(pool.pid)
        await_admission(pool, deadline)

      {:ok, _pid} ->
        :ok
    end
  end
end

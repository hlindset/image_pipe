defmodule ImagePipe.Cache.SharedFileSystem.IOTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.IO.Admission
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImagePipe.Test.SharedIOProbe

  setup ctx do
    pid =
      start_supervised!(
        {CacheIO,
         max_operations: 2,
         max_bytes: 8,
         max_pending: Map.get(ctx, :max_pending, 2),
         max_request_bytes: 256,
         telemetry_prefix: [__MODULE__, ctx.test]}
      )

    pool = CacheIO.client(pid)
    %{pool: pool}
  end

  test "operations execute in a separate local OS process", %{pool: pool} do
    assert {:ok, pid} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
    refute pid == :os.getpid()
    assert {:ok, :nonode@nohost} = CacheIO.run(pool, {:erlang, :node, []}, 0, 1_000)
  end

  @tag capture_log: true
  test "reports retained IO budgets and channel loss through logging and tracing", ctx do
    prefix = [__MODULE__, ctx.test]
    TestExporter.set_receiver(self())
    TestExporter.attach(self(), prefix: prefix)
    Telemetry.attach_default_logger(prefix: prefix)

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
      Telemetry.detach_default_logger()
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(ctx.pool.pid, :watch_admission)

        assert_receive {:span,
                        %Span{
                          name: "image_pipe.cache.shared_io",
                          status: :ok,
                          attributes: %{
                            operation: :usage,
                            jobs: 0,
                            outstanding_bytes: 0,
                            resources: 0,
                            resource_bytes: 0,
                            failed_cleanups: 0
                          }
                        }}

        missing =
          Path.join(System.tmp_dir!(), "shared-io-missing-#{System.unique_integer([:positive])}")

        assert {:ok, lease} = CacheIO.reserve(ctx.pool, 3, {File, :rm, [missing]}, 1_000)
        assert {:error, {:cleanup, _}} = CacheIO.release(ctx.pool, lease, 1_000)
        send(ctx.pool.pid, :watch_admission)

        assert_receive {:span,
                        %Span{
                          status: :error,
                          attributes: %{
                            operation: :usage,
                            resources: 1,
                            resource_bytes: 3,
                            failed_cleanups: 1
                          }
                        }}

        assert {:error, :timeout} =
                 CacheIO.run(ctx.pool, {SharedIOProbe, :wait, [:health]}, 8, 50)

        assert_receive {:span,
                        %Span{
                          name: "image_pipe.cache.shared_io",
                          status: :error,
                          attributes: %{operation: :timeout, jobs: 1, outstanding_bytes: 8}
                        }}

        assert {:error, :saturated} = CacheIO.run(ctx.pool, {:os, :getpid, []}, 1, 1_000)

        assert_receive {:span,
                        %Span{
                          status: :error,
                          attributes: %{operation: :saturated, outstanding_bytes: 8}
                        }}

        assert {:error, _} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)

        assert_receive {:span,
                        %Span{
                          name: "image_pipe.cache.shared_io",
                          status: :error,
                          attributes: %{operation: :unavailable, outstanding_bytes: 8}
                        }}
      end)

    assert log =~ "shared_io: usage ok"
    assert log =~ "[warning] image_pipe cache shared_io: timeout cache_error"
    assert log =~ "[warning] image_pipe cache shared_io: unavailable cache_error"
  end

  test "timeout retains byte reservation until operation completes", %{pool: pool} do
    assert {:error, :timeout} =
             CacheIO.run(pool, {SharedIOProbe, :wait, [:blocked]}, 8, 50)

    assert {:error, :saturated} = CacheIO.run(pool, {:os, :getpid, []}, 1, 1_000)
    assert {:ok, _} = CacheIO.run(pool, {:os, :getpid, []}, 0, 1_000)
  end

  test "an observer receives actual completion after the caller has timed out", %{pool: pool} do
    receipt = make_ref()

    assert {:error, :timeout} =
             CacheIO.run(pool, {SharedIOProbe, :wait, [:observed]}, 8, 50, nil, {self(), receipt})

    refute_received {:shared_io_complete, ^receipt, _result}
    assert {:ok, :release} = CacheIO.run(pool, {:erlang, :send, [:observed, :release]}, 0, 1_000)
    assert_receive {:shared_io_complete, ^receipt, {:finished, {:ok, :released}}}
    assert {:ok, _pid} = CacheIO.run(pool, {:os, :getpid, []}, 8, 1_000)
  end

  test "rejected work is distinguished from an uncertain helper loss", %{pool: pool} do
    rejected = make_ref()

    assert {:error, :saturated} =
             CacheIO.run(pool, {:os, :getpid, []}, 9, 1_000, nil, {self(), rejected})

    assert_receive {:shared_io_complete, ^rejected, {:not_started, {:error, :saturated}}}

    lost = make_ref()

    assert {:error, _reason} =
             CacheIO.run(pool, {:erlang, :halt, []}, 0, 1_000, nil, {self(), lost})

    refute_received {:shared_io_complete, ^lost, _result}
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

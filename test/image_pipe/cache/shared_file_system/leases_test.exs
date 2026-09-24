defmodule ImagePipe.Cache.SharedFileSystem.LeasesTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.Transient
  alias ImagePipe.Test.SharedIOProbe

  setup do
    root = Path.join(System.tmp_dir!(), "shared_leases_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    pool =
      start_supervised!({CacheIO, max_operations: 2, max_resources: 2, max_resource_bytes: 8})

    %{pool: pool, path: Path.join(root, "lease"), root: root}
  end

  test "completed filesystem calls keep their persistent byte reservation", ctx do
    cleanup = {Transient, :remove, [ctx.path]}
    assert {:ok, lease} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)
    assert {:ok, :ok} = CacheIO.run(ctx.pool, {Transient, :create, [ctx.path]}, 0, 1_000, lease)
    assert {:error, :saturated} = CacheIO.reserve(ctx.pool, 1, cleanup, 1_000)
    assert :ok = CacheIO.release(ctx.pool, lease, 1_000)
    refute File.exists?(ctx.path)
    assert {:error, :released} = CacheIO.run(ctx.pool, {:os, :getpid, []}, 0, 1_000, lease)
    assert {:ok, next} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)
    assert :ok = CacheIO.release(ctx.pool, next, 1_000)
  end

  test "zero-byte resources still consume count capacity", ctx do
    cleanup = {Transient, :remove, [ctx.path]}
    assert {:ok, first} = CacheIO.reserve(ctx.pool, 0, cleanup, 1_000)
    assert {:ok, second} = CacheIO.reserve(ctx.pool, 0, cleanup, 1_000)
    assert {:error, :saturated} = CacheIO.reserve(ctx.pool, 0, cleanup, 1_000)
    assert :ok = CacheIO.release(ctx.pool, first, 1_000)
    assert :ok = CacheIO.release(ctx.pool, second, 1_000)
  end

  test "a reservation delayed beyond its request deadline is not allocated", ctx do
    :ok = :sys.suspend(ctx.pool)

    try do
      assert {:error, :timeout} =
               CacheIO.reserve(ctx.pool, 8, {Transient, :remove, [ctx.path]}, 10)
    after
      :sys.resume(ctx.pool)
    end

    assert {:ok, lease} = CacheIO.reserve(ctx.pool, 8, {Transient, :remove, [ctx.path]}, 1_000)
    assert :ok = CacheIO.release(ctx.pool, lease, 1_000)
  end

  test "cleanup waits for a timed-out operation and keeps its reservation", ctx do
    cleanup = {Transient, :remove, [ctx.path]}
    {:ok, lease} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)
    {:ok, :ok} = CacheIO.run(ctx.pool, {Transient, :create, [ctx.path]}, 0, 1_000, lease)

    assert {:error, :timeout} =
             CacheIO.run(ctx.pool, {SharedIOProbe, :wait, [:held]}, 0, 50, lease)

    assert {:error, :timeout} = CacheIO.release(ctx.pool, lease, 10)
    assert File.dir?(ctx.path)
    assert {:error, :saturated} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)
    assert {:error, :released} = CacheIO.run(ctx.pool, {:os, :getpid, []}, 0, 1_000, lease)
    assert {:ok, :release} = CacheIO.run(ctx.pool, {:erlang, :send, [:held, :release]}, 0, 1_000)
    next = await_reservation(ctx.pool, cleanup, System.monotonic_time(:millisecond) + 1_000)
    refute File.exists?(ctx.path)
    assert :ok = CacheIO.release(ctx.pool, next, 1_000)
  end

  test "failed deletion remains charged until a successful retry", ctx do
    blocker = Path.join(ctx.root, "blocker")
    File.write!(ctx.path, "body")
    File.write!(blocker, "blocked")
    cleanup = {SharedIOProbe, :cleanup, [ctx.path, blocker]}
    {:ok, lease} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)

    assert {:error, {:cleanup, {:ok, {:error, :eacces}}}} =
             CacheIO.release(ctx.pool, lease, 1_000)

    assert {:error, :saturated} = CacheIO.reserve(ctx.pool, 8, cleanup, 1_000)
    File.rm!(blocker)
    CacheIO.retry_cleanup(ctx.pool)

    next =
      await_reservation(
        ctx.pool,
        {Transient, :remove, [ctx.path]},
        System.monotonic_time(:millisecond) + 1_000
      )

    refute File.exists?(ctx.path)
    assert :ok = CacheIO.release(ctx.pool, next, 1_000)
  end

  test "owner death reclaims its transient directory", ctx do
    parent = self()
    tasks = start_supervised!(Task.Supervisor)

    {:ok, owner} =
      Task.Supervisor.start_child(tasks, fn ->
        {:ok, lease} = CacheIO.reserve(ctx.pool, 8, {Transient, :remove, [ctx.path]}, 1_000)
        {:ok, :ok} = CacheIO.run(ctx.pool, {Transient, :create, [ctx.path]}, 0, 1_000, lease)
        send(parent, :created)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :created, 1_000
    monitor = Process.monitor(owner)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    next =
      await_reservation(
        ctx.pool,
        {Transient, :remove, [ctx.path]},
        System.monotonic_time(:millisecond) + 1_000
      )

    refute File.exists?(ctx.path)
    assert :ok = CacheIO.release(ctx.pool, next, 1_000)
  end

  defp await_reservation(pool, cleanup, deadline) do
    assert System.monotonic_time(:millisecond) < deadline

    case CacheIO.reserve(pool, 8, cleanup, 1_000) do
      {:error, :saturated} -> await_reservation(pool, cleanup, deadline)
      {:ok, lease} -> lease
    end
  end
end

defmodule ImagePipe.Cache.SharedFileSystem.SourcesTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.SharedFileSystem.Sources
  alias ImagePipe.Source
  alias ImagePipe.Source.Record

  setup context do
    clock = start_supervised!({Agent, fn -> 100 end})

    opts =
      Keyword.merge(
        [clock: fn -> Agent.get(clock, & &1) end],
        Map.get(context, :source_options, [])
      )

    supervisor = start_supervised!({Sources.Supervisor, opts})

    %{
      supervisor: supervisor,
      sources: Sources.client(supervisor),
      tasks: start_supervised!(Task.Supervisor),
      clock: clock
    }
  end

  test "publication requires the active key owner and release revokes it", ctx do
    record = record()
    assert {:ok, lease, :acquired} = Sources.acquire(ctx.sources, "key", 1_000)
    assert {:error, :ownership_lost} = Sources.publish(ctx.sources, "other", lease, record, 1_000)
    assert {:ok, selected} = Sources.publish(ctx.sources, "key", lease, record, 1_000)
    assert {:hit, ^selected} = Sources.lookup(ctx.sources, "key", 1_000)
    assert :ok = Sources.release(ctx.sources, lease)
    assert {:error, :ownership_lost} = Sources.publish(ctx.sources, "key", lease, record, 1_000)
  end

  test "another process cannot publish with a borrowed lease", ctx do
    {:ok, lease, :acquired} = Sources.acquire(ctx.sources, "key", 1_000)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        Sources.release(ctx.sources, lease)
        Sources.publish(ctx.sources, "key", lease, record(), 1_000)
      end)

    assert Task.await(task) == {:error, :ownership_lost}
    assert {:ok, _} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    Sources.release(ctx.sources, lease)
  end

  test "same-key acquisition waits and observes the preceding publication", ctx do
    {:ok, lease, :acquired} = Sources.acquire(ctx.sources, "key", 1_000)
    worker = worker(ctx.supervisor)
    :erlang.trace(worker, true, [:receive, {:tracer, self()}])
    parent = self()

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn ->
        send(parent, :acquiring)
        result = Sources.acquire(ctx.sources, "key", 1_000)
        snapshot = Sources.lookup(ctx.sources, "key", 1_000)

        case result do
          {:ok, next, _} -> Sources.release(ctx.sources, next)
          _ -> :ok
        end

        {result, snapshot}
      end)

    assert_receive :acquiring
    assert_receive {:trace, ^worker, :receive, {:"$gen_call", _, _}}
    assert %{waiters: 1} = Sources.stats(ctx.sources, 1_000)
    :erlang.trace(worker, false, [:receive])
    {:ok, selected} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    Sources.release(ctx.sources, lease)
    assert {{:ok, _, :coalesced}, {:hit, ^selected}} = Task.await(task)
  end

  test "caller death releases ownership for the next request", ctx do
    parent = self()

    {:ok, owner} =
      Task.Supervisor.start_child(ctx.tasks, fn ->
        {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
        send(parent, {:owned, lease})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:owned, old}
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert {:ok, next, _} = Sources.acquire(ctx.sources, "key", 1_000)
    assert {:error, :ownership_lost} = Sources.publish(ctx.sources, "key", old, record(), 1_000)
    assert {:ok, _} = Sources.publish(ctx.sources, "key", next, record(), 1_000)
  end

  test "coordinator restart revokes leases and conservatively protects lost selections", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    {:ok, selected} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    :ok = Sources.invalidate(ctx.sources, "key", selected.revision, 1_000)
    :ok = Supervisor.terminate_child(ctx.supervisor, Sources)
    {:ok, _worker} = Supervisor.restart_child(ctx.supervisor, Sources)
    assert {:error, :ownership_lost} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    {:ok, replacement, _} = Sources.acquire(ctx.sources, "key", 1_000)

    assert {:error, :requires_validation} =
             Sources.discover(ctx.sources, "key", replacement, selected, 1_000)

    assert {:ok, _} = Sources.publish(ctx.sources, "key", replacement, record(), 1_000)
  end

  test "queued requests expire without mutating selection state", ctx do
    worker = worker(ctx.supervisor)
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    :sys.suspend(worker)

    try do
      assert {:error, :timeout} = Sources.publish(ctx.sources, "key", lease, record(), 1)
    after
      :sys.resume(worker)
    end

    assert :miss = Sources.lookup(ctx.sources, "key", 1_000)
  end

  test "expired waiters do not acquire an abandoned lease", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)

    task =
      Task.Supervisor.async_nolink(ctx.tasks, fn -> Sources.acquire(ctx.sources, "key", 1) end)

    assert Task.await(task) == {:error, :timeout}
    Sources.release(ctx.sources, lease)
    assert {:ok, _, _} = Sources.acquire(ctx.sources, "key", 1_000)
  end

  test "waiting caller death removes its queue reservation", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    worker = worker(ctx.supervisor)
    :erlang.trace(worker, true, [:receive, {:tracer, self()}])

    {:ok, waiter} =
      Task.Supervisor.start_child(ctx.tasks, fn -> Sources.acquire(ctx.sources, "key", 1_000) end)

    assert_receive {:trace, ^worker, :receive, {:"$gen_call", _, _}}
    assert %{waiters: 1} = Sources.stats(ctx.sources, 1_000)
    monitor = Process.monitor(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}
    assert_receive {:trace, ^worker, :receive, {:DOWN, _, :process, ^waiter, :killed}}
    assert %{waiters: 0} = Sources.stats(ctx.sources, 1_000)
    :erlang.trace(worker, false, [:receive])
    Sources.release(ctx.sources, lease)
    assert {:ok, _, _} = Sources.acquire(ctx.sources, "key", 1_000)
  end

  @tag source_options: [max_locks: 1, max_waiters: 0]
  test "active ownership and waiter capacity are bounded", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    assert {:error, :saturated} = Sources.acquire(ctx.sources, "other", 1_000)
    assert {:error, :saturated} = Sources.acquire(ctx.sources, "key", 1_000)
    assert %{locks: 1, waiters: 0} = Sources.stats(ctx.sources, 1_000)
    Sources.release(ctx.sources, lease)
    assert {:ok, _, _} = Sources.acquire(ctx.sources, "other", 1_000)
  end

  @tag source_options: [max_pending: 1]
  test "timed-out queued messages retain admission until dequeued", ctx do
    worker = worker(ctx.supervisor)
    :sys.suspend(worker)

    try do
      assert {:error, :timeout} = Sources.lookup(ctx.sources, "key", 1)
      assert {:error, :saturated} = Sources.lookup(ctx.sources, "key", 1)
    after
      :sys.resume(worker)
    end

    _ = :sys.get_state(worker)
    assert :miss = Sources.lookup(ctx.sources, "key", 1_000)
  end

  @tag source_options: [max_request_bytes: 64]
  test "oversized publication messages are rejected before enqueueing", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    assert {:error, :saturated} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    assert :miss = Sources.lookup(ctx.sources, "key", 1_000)
  end

  test "restart preserves the high-water clock when wall time moves backwards", ctx do
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)
    {:ok, _} = Sources.publish(ctx.sources, "key", lease, record(), 1_000)
    Agent.update(ctx.clock, fn _ -> 50 end)
    :ok = Supervisor.terminate_child(ctx.supervisor, Sources)
    {:ok, _} = Supervisor.restart_child(ctx.supervisor, Sources)
    assert {:error, :untrusted_clock} = Sources.lookup(ctx.sources, "key", 1_000)
  end

  test "independent runtimes can retain different source selections", ctx do
    other =
      start_supervised!(
        Supervisor.child_spec({Sources.Supervisor, clock: fn -> 100 end}, id: :other_sources)
      )

    other = Sources.client(other)
    {:ok, a, _} = Sources.acquire(ctx.sources, "key", 1_000)
    {:ok, b, _} = Sources.acquire(other, "key", 1_000)
    {:ok, selected_a} = Sources.publish(ctx.sources, "key", a, record("a"), 1_000)
    {:ok, selected_b} = Sources.publish(other, "key", b, record("b"), 1_000)
    refute selected_a.record.byte_identity == selected_b.record.byte_identity
    assert {:hit, ^selected_a} = Sources.lookup(ctx.sources, "key", 1_000)
    assert {:hit, ^selected_b} = Sources.lookup(other, "key", 1_000)
  end

  test "new validation evidence can be discovered after coordinator recovery", ctx do
    :ok = Supervisor.terminate_child(ctx.supervisor, Sources)
    {:ok, _} = Supervisor.restart_child(ctx.supervisor, Sources)
    Agent.update(ctx.clock, fn _ -> 130 end)
    {:ok, lease, _} = Sources.acquire(ctx.sources, "key", 1_000)

    response = %{
      status: 200,
      headers: %{"cache-control" => ["max-age=60"]},
      request: Req.new(url: "https://example.test/image")
    }

    origin = Source.Origin.from_response(response, {120, 125})
    record = Record.refresh(record(), origin)
    candidate = %ImagePipe.Cache.Input.Snapshot{record: record, revision: make_ref()}
    assert {:hit, selected} = Sources.discover(ctx.sources, "key", lease, candidate, 1_000)
    assert selected.record == record
    assert selected.age_margin == 5
  end

  defp worker(supervisor) do
    [{Sources, worker, _, _}] = Supervisor.which_children(supervisor)
    worker
  end

  defp record(body \\ "image") do
    {:ok, source, _} = Source.from_input({:binary, body}, sources: %{})
    Record.new(source, :crypto.hash(:sha256, body), nil, 90)
  end
end

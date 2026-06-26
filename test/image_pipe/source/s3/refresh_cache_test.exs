defmodule ImagePipe.Source.S3.RefreshCacheTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.RefreshCache.Entry

  defp start_entry(opts) do
    key = Keyword.get(opts, :key, make_ref())
    opts = Keyword.put_new(opts, :key, key)
    opts = Keyword.put_new(opts, :name, nil)
    start_supervised!({Entry, opts})
  end

  test "fetches once on warm-up and serves the cached value on get" do
    test = self()

    fetch_fun = fn ->
      send(test, :fetched)
      {:ok, :creds, :never}
    end

    pid = start_entry(fetch_fun: fetch_fun)

    assert {:ok, :creds} = Entry.get(pid)
    assert_received :fetched
    # second get does not re-fetch
    assert {:ok, :creds} = Entry.get(pid)
    refute_received :fetched
  end

  test "concurrent gets during an in-flight fetch trigger only one fetch" do
    test = self()
    {:ok, gate} = Agent.start_link(fn -> 0 end)

    fetch_fun = fn ->
      Agent.update(gate, &(&1 + 1))
      send(test, {:fetch_started, self()})

      receive do
        :release -> :ok
      after
        1_000 -> :ok
      end

      {:ok, :creds, :never}
    end

    pid = start_entry(fetch_fun: fetch_fun)

    # the warm-on-init fetch has started and is blocked on :release
    assert_receive {:fetch_started, fetch_pid}

    callers = for _ <- 1..5, do: Task.async(fn -> Entry.get(pid) end)

    # ensure the 5 gets have enqueued as waiters before releasing the one fetch
    wait_for_waiters(pid, 5)
    send(fetch_pid, :release)

    results = Task.await_many(callers)
    assert Enum.all?(results, &(&1 == {:ok, :creds}))
    assert Agent.get(gate, & &1) == 1
  end

  defp wait_for_waiters(pid, n) do
    if length(:sys.get_state(pid).waiters) >= n do
      :ok
    else
      wait_for_waiters(pid, n)
    end
  end

  test "fails closed when there is no fresh value and the fetch errors" do
    fetch_fun = fn -> {:error, :unavailable} end
    pid = start_entry(fetch_fun: fetch_fun)
    assert {:error, :unavailable} = Entry.get(pid)
  end

  test "serves the still-fresh value when a refresh fails" do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # now is fixed; expiry is in the future so value stays fresh.
    now = ~U[2026-06-26 00:00:00Z]
    future = ~U[2026-06-26 01:00:00Z]

    fetch_fun = fn ->
      n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
      send(test, {:call, n})

      case n do
        0 -> {:ok, :good, future}
        _ -> {:error, :transient}
      end
    end

    pid =
      start_entry(
        fetch_fun: fetch_fun,
        now_fun: fn -> now end,
        # margin larger than the hour-to-expiry forces an immediate :refresh
        refresh_margin_ms: 3_600_001
      )

    assert_receive {:call, 0}
    # background refresh fires (and fails), but value is still fresh:
    assert_receive {:call, 1}
    # force the failed-refresh result to be applied before asserting, so this
    # actually exercises the serve-stale-on-error branch (not just the pre-error
    # state).
    _ = :sys.get_state(pid)
    assert {:ok, :good} = Entry.get(pid)
  end

  test "does not serve an expired value; re-fetches on get" do
    test = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)
    past = ~U[2026-06-26 00:00:00Z]
    later = ~U[2026-06-26 02:00:00Z]
    {:ok, clock} = Agent.start_link(fn -> past end)

    fetch_fun = fn ->
      n = Agent.get_and_update(calls, fn n -> {n, n + 1} end)
      send(test, {:call, n})
      {:ok, {:creds, n}, ~U[2026-06-26 00:30:00Z]}
    end

    pid =
      start_entry(
        fetch_fun: fetch_fun,
        now_fun: fn -> Agent.get(clock, & &1) end,
        refresh_margin_ms: 0
      )

    assert_receive {:call, 0}
    assert {:ok, {:creds, 0}} = Entry.get(pid)

    # advance the clock past expiry; the cached value is now stale
    Agent.update(clock, fn _ -> later end)
    assert {:ok, {:creds, 1}} = Entry.get(pid)
    assert_received {:call, 1}
  end
end

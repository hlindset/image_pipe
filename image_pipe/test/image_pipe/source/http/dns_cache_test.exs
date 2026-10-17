defmodule ImagePipe.Source.HTTP.DnsCacheTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.DnsCache

  @address {93, 184, 216, 34}

  setup context do
    name = Module.concat(__MODULE__, "Cache#{System.unique_integer([:positive])}")
    opts = Keyword.merge([name: name], Map.get(context, :cache, []))
    start_supervised!({DnsCache, opts})
    %{cache: name}
  end

  defp counting_lookup(result) do
    test_pid = self()

    fn host ->
      send(test_pid, {:lookup, host})
      result
    end
  end

  test "answers a repeated lookup from the cache", %{cache: cache} do
    lookup = counting_lookup({:ok, [@address]})

    assert DnsCache.resolve(cache, "origin.test", lookup) == {:ok, [@address]}
    assert DnsCache.resolve(cache, "origin.test", lookup) == {:ok, [@address]}

    assert_received {:lookup, "origin.test"}
    refute_received {:lookup, _host}
  end

  test "caches each host separately", %{cache: cache} do
    lookup = fn
      "a.test" -> {:ok, [{192, 0, 2, 1}]}
      "b.test" -> {:ok, [{192, 0, 2, 2}]}
    end

    assert DnsCache.resolve(cache, "a.test", lookup) == {:ok, [{192, 0, 2, 1}]}
    assert DnsCache.resolve(cache, "b.test", lookup) == {:ok, [{192, 0, 2, 2}]}
  end

  @tag cache: [lifetime: 0]
  test "looks a host up again once its answer expires", %{cache: cache} do
    lookup = counting_lookup({:ok, [@address]})

    DnsCache.resolve(cache, "origin.test", lookup)
    DnsCache.resolve(cache, "origin.test", lookup)

    assert_received {:lookup, "origin.test"}
    assert_received {:lookup, "origin.test"}
  end

  test "doesn't cache a failed lookup", %{cache: cache} do
    lookup = counting_lookup({:error, :nxdomain})

    assert DnsCache.resolve(cache, "missing.test", lookup) == {:error, :nxdomain}
    assert DnsCache.resolve(cache, "missing.test", lookup) == {:error, :nxdomain}

    assert_received {:lookup, "missing.test"}
    assert_received {:lookup, "missing.test"}
  end

  test "looks a host up again after it is invalidated", %{cache: cache} do
    lookup = counting_lookup({:ok, [@address]})

    DnsCache.resolve(cache, "origin.test", lookup)
    DnsCache.invalidate(cache, "origin.test")
    DnsCache.resolve(cache, "origin.test", lookup)

    assert_received {:lookup, "origin.test"}
    assert_received {:lookup, "origin.test"}
  end

  @tag cache: [max_entries: 1]
  test "stops caching new hosts when full", %{cache: cache} do
    lookup = counting_lookup({:ok, [@address]})

    DnsCache.resolve(cache, "a.test", lookup)
    DnsCache.resolve(cache, "b.test", lookup)
    DnsCache.resolve(cache, "b.test", lookup)
    DnsCache.resolve(cache, "a.test", lookup)

    assert_received {:lookup, "a.test"}
    assert_received {:lookup, "b.test"}
    assert_received {:lookup, "b.test"}
    refute_received {:lookup, _host}
  end

  @tag cache: [join_within: 60_000]
  test "shares one lookup between concurrent requests for a host", %{cache: cache} do
    test_pid = self()

    lookup = fn host ->
      send(test_pid, {:lookup, host, self()})

      receive do
        :release -> {:ok, [@address]}
      end
    end

    callers =
      for _ <- 1..3 do
        Task.async(fn -> DnsCache.resolve(cache, "origin.test", lookup) end)
      end

    assert_receive {:lookup, "origin.test", lookup_pid}
    # Every caller has joined the pending lookup once the server has handled
    # their calls.
    wait_for_waiters(cache, 3)
    send(lookup_pid, :release)

    assert Enum.map(callers, &Task.await/1) == List.duplicate({:ok, [@address]}, 3)
    refute_received {:lookup, _host, _pid}
  end

  test "doesn't hold up other hosts while a lookup is pending", %{cache: cache} do
    test_pid = self()

    slow = fn _host ->
      send(test_pid, {:slow_started, self()})
      receive do: (:release -> {:ok, [@address]})
    end

    task = Task.async(fn -> DnsCache.resolve(cache, "slow.test", slow) end)
    assert_receive {:slow_started, lookup_pid}

    assert DnsCache.resolve(cache, "fast.test", fn _ -> {:ok, [{192, 0, 2, 9}]} end) ==
             {:ok, [{192, 0, 2, 9}]}

    send(lookup_pid, :release)
    assert Task.await(task) == {:ok, [@address]}
  end

  @tag cache: [join_within: 0]
  test "starts a new lookup instead of joining one that has run too long", %{cache: cache} do
    test_pid = self()

    lookup = fn host ->
      send(test_pid, {:lookup, host, self()})
      receive do: (:release -> {:ok, [@address]})
    end

    first = Task.async(fn -> DnsCache.resolve(cache, "origin.test", lookup) end)
    assert_receive {:lookup, "origin.test", first_lookup}
    second = Task.async(fn -> DnsCache.resolve(cache, "origin.test", lookup) end)
    assert_receive {:lookup, "origin.test", second_lookup}

    send(second_lookup, :release)
    assert Task.await(second) == {:ok, [@address]}
    send(first_lookup, :release)
    assert Task.await(first) == {:ok, [@address]}
  end

  @tag cache: [join_within: 60_000]
  test "answers every waiting caller with an error when the lookup dies", %{cache: cache} do
    test_pid = self()

    lookup = fn host ->
      send(test_pid, {:lookup, host, self()})
      receive do: (:release -> {:ok, [@address]})
    end

    callers =
      for _ <- 1..2 do
        Task.async(fn -> DnsCache.resolve(cache, "origin.test", lookup) end)
      end

    assert_receive {:lookup, "origin.test", lookup_pid}
    wait_for_waiters(cache, 2)
    Process.exit(lookup_pid, :kill)

    assert Enum.map(callers, &Task.await/1) == [{:error, :killed}, {:error, :killed}]
  end

  @tag cache: [max_entries: 1, lifetime: 0]
  test "caches new hosts again once a sweep removes expired answers", %{cache: cache} do
    DnsCache.resolve(cache, "a.test", fn _ -> {:ok, [@address]} end)
    send(cache, :sweep)
    _ = :sys.get_state(cache)

    DnsCache.resolve(cache, "b.test", fn _ -> {:ok, [@address]} end)
    assert [{"b.test", [@address], _expires_at}] = :ets.lookup(cache, "b.test")
  end

  test "looks hosts up directly while the cache isn't running", %{cache: cache} do
    stop_supervised!(DnsCache)

    assert DnsCache.resolve(cache, "origin.test", fn _ -> {:ok, [@address]} end) ==
             {:ok, [@address]}
  end

  defp wait_for_waiters(cache, count) do
    %{pending: pending} = :sys.get_state(cache)

    if Enum.any?(pending, fn {_pid, {_host, waiters, _started, _ref}} ->
         length(waiters) == count
       end),
       do: :ok,
       else: wait_for_waiters(cache, count)
  end
end

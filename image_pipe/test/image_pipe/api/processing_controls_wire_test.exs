defmodule ImagePipe.API.ProcessingControlsWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.ProcessingPool
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.ProcessingSource

  @image File.read!("priv/static/images/beach.jpg")

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    %{tasks: tasks, prefix: [__MODULE__, test]}
  end

  test "concurrent Plug and Elixir requests share admission across all terminals", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    config = config(pool, context.prefix)
    mount = ImagePipe.Plug.init(config: config)

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}

    for terminal <- [:image, :blurhash, :lqip_css, :info] do
      path = terminal_path(terminal)
      overloaded = request(mount, path)
      assert overloaded.status == 503
      assert overloaded.resp_body == "image processing overloaded"
      assert Plug.Conn.get_resp_header(overloaded, "retry-after") == ["10"]

      builder = ImagePipe.URL.new() |> ImagePipe.URL.output(terminal: terminal)

      assert {:error, {:processing, :overloaded}} =
               ImagePipe.run(config, builder, {:binary, @image})
    end

    refute_received {:fetch, ["ready"], _}
    send(worker, :continue)
    assert Task.await(active).status == 200

    for terminal <- [:blurhash, :lqip_css, :info] do
      assert request(mount, terminal_path(terminal)).status == 200
    end

    result = request(mount, "w=32/format=png")
    assert result.status == 200
    assert Image.width(Image.from_binary!(result.resp_body)) == 32
    assert %{active: 0, queued: 0} = ProcessingPool.stats(pool)
  end

  test "image and terminal cache hits plus conditional responses bypass a full pool", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    opts = observed(pool, context.prefix)
    mount = Caches.plug(opts)

    warmed =
      for options <- ["w=32/format=jpeg", "output=info", "output=blurhash", "output=lqip-css"] do
        response = request(mount, options)
        assert response.status == 200
        {options, response}
      end

    # Cache writes finish after the response; the hits below need them stored.
    Caches.await_writes(opts)

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}

    for {options, original} <- warmed do
      cached = request(mount, options)
      assert cached.status == 200
      assert cached.resp_body == original.resp_body
      [etag] = Plug.Conn.get_resp_header(cached, "etag")

      conditional =
        conn(:get, "/#{options}/src/ready")
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(mount)

      assert conditional.status == 304
    end

    send(worker, :continue)
    assert Task.await(active).status == 200
  end

  test "processing deadlines return 503 while unfinished work keeps its slot", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, processing_timeout: 100})
    mount = ImagePipe.Plug.init(config: config(pool, context.prefix))
    event = context.prefix ++ [:processing, :execute, :stop]
    ref = :telemetry_test.attach_event_handlers(self(), [event])
    on_exit(fn -> :telemetry.detach(ref) end)

    for options <- ["w=32", "output=blurhash", "output=lqip-css", "output=info"] do
      timed = request(mount, options, "blocked")
      assert timed.status == 503
      assert timed.resp_body == "image processing timeout"
      assert_receive {:fetch, ["blocked"], worker}
      assert %{active: 1, queued: 0} = ProcessingPool.stats(pool)
      send(worker, :continue)
      assert_receive {^event, ^ref, _measurements, %{result: :timeout}}, 1_000
      assert %{active: 0, queued: 0} = ProcessingPool.stats(pool)
      assert ProcessingPool.run(pool, fn -> :recovered end, []) == :recovered
    end
  end

  test "queue wait is bounded and rejects without source fetch", context do
    pool =
      start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 1, queue_timeout: 1_000})

    mount = ImagePipe.Plug.init(config: config(pool, context.prefix))

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}
    expired = request(mount, "output=info")
    assert expired.status == 503
    assert expired.resp_body == "image processing queue timeout"
    assert Plug.Conn.get_resp_header(expired, "retry-after") == ["1"]
    refute_received {:fetch, ["ready"], _}
    send(worker, :continue)
    assert Task.await(active).status == 200
  end

  test "a stored terminal's generation cost excludes the wait for a processing slot", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    opts = observed(pool, context.prefix)
    mount = Caches.plug(opts)
    test = self()

    Task.Supervisor.async_nolink(context.tasks, fn ->
      ProcessingPool.within(pool, self(), [], fn ->
        send(test, :holding)
        await_queued(pool)
        queued_at = System.monotonic_time(:microsecond)
        # Holds the slot so the request below queues; nothing races this.
        Process.sleep(200)
        send(test, {:held, System.monotonic_time(:microsecond) - queued_at})
      end)
    end)

    assert_receive :holding
    started_at = System.monotonic_time(:microsecond)
    assert request(mount, "output=info").status == 200
    elapsed_us = System.monotonic_time(:microsecond) - started_at
    Caches.await_writes(opts)
    assert_received {:held, held_us}
    assert_received {:cache_open_sink, _hash, %{cost_us: cost_us}}

    # The request was queued for at least `held_us` of its `elapsed_us`, so a
    # cost that excludes the wait fits in the remainder however slow the
    # generation itself is.
    assert cost_us <= elapsed_us - held_us
  end

  test "a normal request takes a full queue's place from a low-priority one", context do
    pool =
      start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 1, queue_timeout: 2_500})

    mount = ImagePipe.Plug.init(config: config(pool, context.prefix))

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}

    low =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32/priority=low") end)

    await_queued(pool)
    normal = Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=33") end)

    pushed_out = Task.await(low)
    assert pushed_out.status == 503
    assert pushed_out.resp_body == "image processing overloaded"
    assert Plug.Conn.get_resp_header(pushed_out, "retry-after") == ["3"]

    send(worker, :continue)
    assert Task.await(active).status == 200
    assert Image.width(Image.from_binary!(Task.await(normal).resp_body)) == 33
  end

  test "low-priority and normal requests share one cached result", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    opts = observed(pool, context.prefix)
    mount = Caches.plug(opts)

    low = request(mount, "w=32/priority=low")
    assert low.status == 200
    Caches.await_writes(opts)

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=40", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}
    normal = request(mount, "w=32")
    assert normal.status == 200
    assert normal.resp_body == low.resp_body

    assert Plug.Conn.get_resp_header(normal, "etag") ==
             Plug.Conn.get_resp_header(low, "etag")

    send(worker, :continue)
    assert Task.await(active).status == 200
  end

  test "a normal request doesn't wait on a low-priority request for the same image", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    opts = observed(pool, context.prefix)
    mount = Caches.plug(opts)

    active =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=40", "blocked") end)

    assert_receive {:fetch, ["blocked"], worker}

    low =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32/priority=low") end)

    await_stats(pool, %{queued: 1, low_queued: 1})
    normal = Task.Supervisor.async_nolink(context.tasks, fn -> request(mount, "w=32") end)
    await_stats(pool, %{queued: 2, low_queued: 1})

    send(worker, :continue)
    assert Task.await(active).status == 200
    assert Task.await(normal).status == 200
    assert Task.await(low).status == 200
  end

  defp await_stats(pool, expected, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    stats = ProcessingPool.stats(pool)

    cond do
      Map.take(stats, Map.keys(expected)) == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("pool stats #{inspect(stats)} never matched #{inspect(expected)}")

      true ->
        await_stats(pool, expected, deadline)
    end
  end

  defp await_queued(pool) do
    case ProcessingPool.stats(pool) do
      %{queued: 0} -> await_queued(pool)
      _queued -> :ok
    end
  end

  test "invalid requests and processing configuration fail before work", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    mount = ImagePipe.Plug.init(config: config(pool, context.prefix))
    assert request(mount, "w=invalid").status == 400
    assert %{active: 0, queued: 0} = ProcessingPool.stats(pool)
    refute_received {:fetch, _, _}
    assert_raise ArgumentError, fn -> ImagePipe.config(processing_pool: "untrusted") end
  end

  defp config(pool, prefix), do: ImagePipe.config(options(pool, prefix))

  defp observed(pool, prefix), do: pool |> options(prefix) |> CacheObserver.observe()

  defp options(pool, prefix) do
    [
      processing_pool: pool,
      telemetry_prefix: prefix,
      sources: [
        path: [
          adapter: ProcessingSource,
          match: :path,
          options: [test: self(), bytes: @image]
        ]
      ]
    ]
  end

  defp request(mount, options, source \\ "ready"),
    do: ImagePipe.Plug.call(conn(:get, "/#{options}/src/#{source}"), mount)

  defp terminal_path(:image), do: "w=32"
  defp terminal_path(:lqip_css), do: "output=lqip-css"
  defp terminal_path(terminal), do: "output=#{terminal}"
end

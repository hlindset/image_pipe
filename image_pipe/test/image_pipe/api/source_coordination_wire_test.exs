defmodule ImagePipe.API.SourceCoordinationWireTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Source.Origin
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.ProcessingSource

  @image Image.new!(64, 48, color: :red) |> Image.write!(:memory, suffix: ".jpg")

  setup %{test: test} do
    root =
      Path.join(System.tmp_dir!(), "source-coordination-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(handler, prefix ++ [:cache, :coordination], &__MODULE__.event/4, self())

    :telemetry.attach(
      {handler, :generated},
      prefix ++ [:transform, :execute, :stop],
      &__MODULE__.generated/4,
      self()
    )

    on_exit(fn -> :telemetry.detach({handler, :generated}) end)
    on_exit(fn -> :telemetry.detach(handler) end)

    %{root: root, prefix: prefix, tasks: start_supervised!(Task.Supervisor)}
  end

  def event(_event, _measurements, metadata, test), do: send(test, {:coordination, metadata})
  def generated(_event, _measurements, _metadata, test), do: send(test, {:generated, self()})

  test "without a cache, variants of one original download at once", context do
    mount = start(context, [])
    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 8) end)
    assert_receive {:streaming, other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
    refute_received {:coordination, %{pool: :input}}
  end

  test "without an originals cache, new variants of a known original download at once",
       context do
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    warm = async(context, fn -> request(mount, 16) end)
    assert_receive {:streaming, worker}
    send(worker, :continue)
    assert Task.await(warm).status == 200
    await_writes(context)

    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 8) end)
    assert_receive {:streaming, other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  test "without an originals cache, cold requests for different sizes download at once",
       context do
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 8) end)
    assert_receive {:streaming, other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  for {name, caches} <- [
        {"with only a processed-image cache", [:cache]},
        {"with both caches", [:cache, :input_cache]}
      ] do
    test "#{name}, identical cold requests share one download and one image", context do
      mount = start(context, cache_options(context, unquote(caches)))
      first = async(context, fn -> request(mount, 12) end)
      assert_receive {:fetch, ["original"], _}
      assert_receive {:streaming, leader}
      second = async(context, fn -> request(mount, 12) end)
      assert_receive {:coordination, %{operation: :download, result: :waiting}}
      send(leader, :continue)

      original = Task.await(first)
      assert original.status == 200
      assert Task.await(second).resp_body == original.resp_body
      assert_received {:generated, _}
      refute_received {:generated, _}
      refute_received {:fetch, ["original"], _}
    end
  end

  test "identical cold requests share one download of an original the origin marks no-cache",
       context do
    mount =
      start(context,
        cache: [root: Path.join(context.root, "output")],
        origin: origin("no-cache")
      )

    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:fetch, ["original"], _}
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)

    original = Task.await(first)
    assert original.status == 200
    assert Task.await(second).resp_body == original.resp_body
    assert_received {:generated, _}
    refute_received {:generated, _}
    refute_received {:fetch, ["original"], _}
  end

  test "without an originals cache, identical requests for a known original share one image",
       context do
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    warm = async(context, fn -> request(mount, 16) end)
    assert_receive {:streaming, worker}
    send(worker, :continue)
    assert Task.await(warm).status == 200
    assert_receive {:generated, _}
    await_writes(context)

    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :output, result: :waiting}}
    send(leader, :continue)

    original = Task.await(first)
    assert Task.await(second).resp_body == original.resp_body
    assert_received {:generated, _}
    refute_received {:generated, _}
    refute_received {:streaming, _}
  end

  test "a download the origin forbids storing releases the requests waiting for it", context do
    mount =
      start(context,
        cache: [root: Path.join(context.root, "output")],
        input_cache: [root: Path.join(context.root, "input")],
        origin: origin("no-store")
      )

    first = async(context, fn -> request(mount, 12, "blocked") end)
    assert_receive {:fetch, ["blocked"], leader}
    second = async(context, fn -> request(mount, 8, "blocked") end)
    await_source_waiter(second.pid)
    send(leader, :continue)
    assert_receive {:coordination, %{pool: :input, result: :bypass, reason: :not_stored}}
    assert_receive {:fetch, ["blocked"], other}
    send(other, :continue)
    assert_receive {:streaming, ^leader}
    assert_receive {:streaming, ^other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  test "an identical request is released when the origin forbids storing the original",
       context do
    mount =
      start(context,
        cache: [root: Path.join(context.root, "output")],
        origin: origin("no-store")
      )

    first = async(context, fn -> request(mount, 12, "blocked") end)
    assert_receive {:fetch, ["blocked"], leader}
    second = async(context, fn -> request(mount, 12, "blocked") end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)
    assert_receive {:streaming, ^leader}

    assert_receive {:coordination, %{operation: :download, result: :bypass, reason: :not_stored}}

    assert_receive {:fetch, ["blocked"], other}
    send(other, :continue)
    assert_receive {:streaming, ^other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  test "an identical request says when a watermark that may not be stored ends its wait",
       context do
    mark = Image.new!(8, 8, color: :blue) |> Image.write!(:memory, suffix: ".png")

    marks = [
      adapter: ProcessingSource,
      match: [prefix: "marks"],
      options: [test: self(), bytes: mark, copy?: true, origin: origin("no-store")]
    ]

    mount =
      start(context,
        cache: [root: Path.join(context.root, "output")],
        sources: [marks: marks],
        watermarks: %{logo: [source: "marks/mark"]}
      )

    path = "/w=12/wm=logo/format=png/src/original"
    first = async(context, fn -> ImagePipe.Plug.call(conn(:get, path), mount) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> ImagePipe.Plug.call(conn(:get, path), mount) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)

    assert_receive {:coordination,
                    %{operation: :download, result: :bypass, reason: :watermark_not_stored}}

    assert_receive {:streaming, other}
    send(other, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  test "an identical request waits for the image once the first request makes it", context do
    test = self()

    :telemetry.attach(
      {context.test, :generating},
      context.prefix ++ [:transform, :execute, :start],
      fn _, _, _, _ ->
        send(test, {:generating, self()})
        receive do: (:go -> :ok)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({context.test, :generating}) end)
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    first = held(context, fn -> request(mount, 12) end)
    assert_receive {:fetch, ["original"], _}
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)
    assert_receive {:generating, generation}
    assert_receive {:coordination, %{operation: :output, result: :waiting}}
    send(generation, :go)

    assert_receive {:done, ^first, original}
    assert Task.await(second).resp_body == original.resp_body
    refute_received {:generating, _}
    refute_received {:fetch, ["original"], _}
  end

  for segment <- ["failing", "raising"] do
    test "an identical request stops waiting when the first request's fetch is #{segment}",
         context do
      mount = start(context, cache: [root: Path.join(context.root, "output")])
      path = "blocked/#{unquote(segment)}"
      first = held(context, fn -> rescued(fn -> request(mount, 12, path) end) end)
      assert_receive {:fetch, ["blocked", unquote(segment)], leader}
      second = async(context, fn -> rescued(fn -> request(mount, 12, path) end) end)
      assert_receive {:coordination, %{operation: :download, result: :waiting}}
      send(leader, :continue)

      assert_receive {:coordination, %{operation: :download, result: :bypass} = event}
      refute Map.has_key?(event, :reason)
      assert_receive {:fetch, ["blocked", unquote(segment)], other}
      send(other, :continue)
      assert_receive {:done, ^first, response}
      assert outcome(Task.await(second)) == outcome(response)
    end
  end

  test "an identical request stops waiting a second after the source's fetch deadline",
       context do
    mount =
      start(context, cache: [root: Path.join(context.root, "output")], fetch_timeout: 200)

    first = async(context, fn -> request(mount, 12, "blocked") end)
    assert_receive {:fetch, ["blocked"], leader}
    second = async(context, fn -> request(mount, 12, "blocked") end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    refute_receive {:coordination, %{operation: :download, result: :bypass}}, 1_000
    assert_receive {:coordination, %{operation: :download, result: :bypass}}, 5_000
    assert_receive {:fetch, ["blocked"], other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert_receive {:streaming, ^leader}
    assert_receive {:streaming, ^other}
    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  test "a low-priority request waits for an identical normal one but never leads", context do
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    low = async(context, fn -> request(mount, "w=12/priority=low") end)
    assert_receive {:streaming, low_worker}
    normal = async(context, fn -> request(mount, "w=12") end)
    assert_receive {:streaming, normal_worker}
    for worker <- [low_worker, normal_worker], do: send(worker, :continue)
    Task.await(low)
    Task.await(normal)

    mount = start(context, cache: [root: Path.join(context.root, "second")])
    flush_fetches()
    normal = async(context, fn -> request(mount, "w=12") end)
    assert_receive {:fetch, ["original"], _}
    assert_receive {:streaming, leader}
    low = async(context, fn -> request(mount, "w=12/priority=low") end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)
    assert Task.await(normal).status == 200
    assert Task.await(low).status == 200
    refute_received {:fetch, ["original"], _}
  end

  test "watermarked requests for different sizes download at once", context do
    mark = Image.new!(8, 8, color: :blue) |> Image.write!(:memory, suffix: ".png")

    marks = [
      adapter: ProcessingSource,
      match: [prefix: "marks"],
      options: [test: self(), bytes: mark, copy?: true, origin: origin("no-store")]
    ]

    mount =
      start(context,
        cache: [root: Path.join(context.root, "output")],
        sources: [marks: marks],
        watermarks: %{logo: [source: "marks/mark"]}
      )

    first = async(context, fn -> request(mount, "w=12/wm=logo") end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, "w=8/wm=logo") end)
    assert_receive {:streaming, other}
    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
    refute_received {:coordination, %{result: :waiting}}
  end

  test "the request summary says when a request used another's download", context do
    test = self()

    :telemetry.attach(
      {context.test, :summary},
      context.prefix ++ [:request, :summary],
      fn _, _, summary, _ -> send(test, {:summary, summary}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({context.test, :summary}) end)
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)
    Task.await(first)
    Task.await(second)

    summaries = for _ <- 1..2, do: assert_receive({:summary, summary}) && summary
    assert Enum.count(summaries, &(&1[:download] == :coalesced)) == 1
    assert Enum.count(summaries, &(not Map.has_key?(&1, :download))) == 1
  end

  test "an identical request is released when the first answers 304", context do
    probe = start(context, cache: [root: Path.join(context.root, "probe")])
    warm = async(context, fn -> request(probe, 12) end)
    assert_receive {:streaming, worker}
    send(worker, :continue)
    [etag] = Plug.Conn.get_resp_header(Task.await(warm), "etag")

    mount = start(context, cache: [root: Path.join(context.root, "output")])
    path = "/w=12/format=png/src/original"

    first =
      held(context, fn ->
        conn(:get, path)
        |> Plug.Conn.put_req_header("if-none-match", etag)
        |> ImagePipe.Plug.call(mount)
      end)

    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    send(leader, :continue)
    assert_receive {:done, ^first, not_modified}
    assert not_modified.status == 304
    assert_receive {:streaming, other}
    send(other, :continue)
    assert Task.await(second).status == 200
  end

  test "an identical request leads the download when the first request dies", context do
    mount = start(context, cache: [root: Path.join(context.root, "output")])
    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, _leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{operation: :download, result: :waiting}}
    Process.exit(first.pid, :kill)

    assert_receive {:coordination, %{operation: :download, result: :acquired}}
    assert_receive {:streaming, other}
    send(other, :continue)
    assert Task.await(second).status == 200
  end

  test "identical requests for a source with caching turned off download at once", context do
    mount =
      start(context, cache: [root: Path.join(context.root, "output")], internal_cache: :disabled)

    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
    refute_received {:coordination, %{operation: :download}}
  end

  # Each download sends its process once its first bytes are read, and holds
  # the rest until that process gets `:continue`.
  defp start(context, options) do
    {origin, options} = Keyword.pop(options, :origin)
    {sources, options} = Keyword.pop(options, :sources, [])
    {fetch_timeout, options} = Keyword.pop(options, :fetch_timeout)
    {internal_cache, caches} = Keyword.pop(options, :internal_cache, :enabled)
    test = self()

    stream =
      Stream.map([@image], fn bytes ->
        send(test, {:streaming, self()})
        receive do: (:continue -> bytes)
      end)

    source = [
      test: test,
      bytes: @image,
      copy?: true,
      stream: stream,
      origin: origin,
      internal_cache: internal_cache
    ]

    source = if fetch_timeout, do: [fetch_timeout: fetch_timeout] ++ source, else: source

    [
      telemetry_prefix: context.prefix,
      sources: sources ++ [path: [adapter: ProcessingSource, match: :path, options: source]]
    ]
    |> Keyword.merge(caches)
    |> Caches.start!()
    |> Caches.plug()
  end

  defp cache_options(context, caches) do
    for cache <- caches,
        do: {cache, [root: Path.join(context.root, Atom.to_string(cache))]}
  end

  defp origin(control) do
    now = System.os_time(:second)

    %Origin{
      status: 200,
      headers: %{"cache-control" => [control]},
      requested_at: now,
      received_at: now,
      resource: :crypto.hash(:sha256, "origin"),
      vary: %{}
    }
  end

  defp async(context, fun), do: Task.Supervisor.async_nolink(context.tasks, fun)

  # Runs `fun` in a process that stays alive after it answers, as a
  # keep-alive connection's would, and sends `{:done, pid, result}`.
  defp held(context, fun) do
    test = self()

    %Task{pid: pid} =
      async(context, fn ->
        send(test, {:done, self(), fun.()})
        receive do: (:release -> :ok)
      end)

    pid
  end

  defp outcome(%Plug.Conn{status: status}), do: status
  defp outcome(%_{} = exception), do: exception.__struct__

  defp flush_fetches do
    receive do
      {:fetch, _segments, _pid} -> flush_fetches()
    after
      0 -> :ok
    end
  end

  defp rescued(fun) do
    fun.()
  rescue
    exception -> exception
  end

  defp request(mount, width, source \\ "original")

  defp request(mount, options, source) when is_binary(options),
    do: ImagePipe.Plug.call(conn(:get, "/#{options}/format=png/src/#{source}"), mount)

  defp request(mount, width, source), do: request(mount, "w=#{width}", source)

  defp await_writes(context),
    do: Caches.await_writes(cache: [root: Path.join(context.root, "output")])

  defp await_source_waiter(pid, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    waiting? =
      ImagePipe.Cache.Work
      |> :sys.get_state()
      |> Map.fetch!(:locks)
      |> Enum.any?(fn {_key, lock} ->
        Enum.any?(lock.waiters, &match?({_ref, {^pid, _tag}, _context}, &1))
      end)

    cond do
      waiting? ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the request never waited for the download")

      true ->
        receive after: (1 -> await_source_waiter(pid, deadline))
    end
  end
end

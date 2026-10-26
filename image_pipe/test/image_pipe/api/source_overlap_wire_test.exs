defmodule ImagePipe.API.SourceOverlapWireTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Origin
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.PacedSourceOrigin
  alias ImagePipe.Test.ProcessingSource
  alias Vix.Vips.Image, as: VipsImage

  setup %{test: test} = tags do
    body = File.read!("priv/static/images/" <> Map.get(tags, :fixture, "waterfall.jpg"))
    origin = start_supervised!({PacedSourceOrigin, test_pid: self(), body: body})
    assert_receive {:origin_ready, ^origin, url}
    root = Path.join(System.tmp_dir!(), "overlap-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    if tags[:broken_cache] do
      File.mkdir_p!(root)
      File.write!(Path.join(root, "output"), "unavailable")
    end

    prefix = [__MODULE__, test]
    event = prefix ++ [:source, :fetch_decode, :stop]
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        event,
        fn _, _, meta, pid ->
          send(pid, {:decode_worker, self()})
          send(pid, {:decoded, meta})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    options =
      Caches.start!(
        telemetry_prefix: prefix,
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000,
        sources: [
          url: [
            adapter: HTTP,
            match: [scheme: ["http", "https"]],
            options: [
              allowed_hosts: [URI.parse(url).authority],
              address_policy: [allow_loopback: true]
            ]
          ]
        ],
        cache: [root: Path.join(root, "output")],
        http_cache: :auto
      )

    tasks = start_supervised!(Task.Supervisor)

    %{
      options: options,
      config: Caches.plug(options),
      origin: origin,
      url: url,
      tasks: tasks,
      body: body,
      root: root
    }
  end

  test "opens progressive JPEG before EOF, preserves pixels, and reuses cached output", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    assert {:ok, image} = Image.from_binary(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {100, 150}

    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 100])
      |> ImagePipe.URL.output(format: :png)

    assert {:ok, reference} = ImagePipe.run(reference_config(), builder, {:binary, context.body})

    assert VipsImage.write_to_binary(image) ==
             VipsImage.write_to_binary(Image.from_binary!(reference.data))

    cached = request(context)
    assert cached.status == 200
    assert cached.resp_body == response.resp_body

    assert Plug.Conn.get_resp_header(cached, "etag") ==
             Plug.Conn.get_resp_header(response, "etag")

    [etag] = Plug.Conn.get_resp_header(response, "etag")

    conditional =
      Plug.Test.conn(:get, "/w=100/format=png/src/#{context.url}/image")
      |> Plug.Conn.put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(context.config)

    assert conditional.status == 304
    refute_received {:decoded, _}
  end

  test "a skipped source found during overlap streams the completed download", context do
    context = restart(context, Keyword.put(context.options, :skip_processing_formats, [:jpeg]))

    task =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        Plug.Test.conn(:get, "/w=100/src/#{context.url}/image")
        |> ImagePipe.Plug.call(context.config)
      end)

    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok, skipped: true}}, 2_000
    send(origin, :continue)
    response = Task.await(task, 10_000)

    assert response.status == 200
    assert response.resp_body == context.body
    assert Plug.Conn.get_resp_header(response, "content-type") == ["image/jpeg"]
  end

  test "empty source chunks do not break overlap observation", context do
    <<prefix::binary-size(512 * 1024), tail::binary>> = context.body

    stream =
      Stream.map([prefix, "", tail], fn
        "" ->
          Process.send_after(self(), :empty_chunk, 20)
          receive do: (:empty_chunk -> "")

        bytes ->
          bytes
      end)

    now = System.system_time(:second)

    origin =
      Origin.from_response(
        %{
          status: 200,
          headers: %{"content-length" => [Integer.to_string(byte_size(context.body))]},
          request: %{url: "http://source.test/image", headers: %{}}
        },
        {now, now}
      )

    context =
      restart(context,
        sources: [
          path: [
            adapter: ProcessingSource,
            match: :path,
            options: [
              test: self(),
              bytes: context.body,
              stream: stream,
              origin: origin,
              copy?: true
            ]
          ]
        ],
        cache: [root: Path.join(context.root, "output")],
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000
      )

    response =
      Plug.Test.conn(:get, "/w=100/format=png/src/empty.jpg")
      |> ImagePipe.Plug.call(context.config)

    assert response.status == 200
    assert_pixels(response, context, [])
    assert_receive {:closed, ["empty.jpg"]}
  end

  test "overlap selected after a large burst preserves pixels", context do
    <<head::binary-size(64 * 1024), burst::binary-size(1_500_000), tail::binary>> = context.body
    observer = self()

    stream =
      [head, burst, tail]
      |> Stream.with_index()
      |> Stream.map(fn
        {bytes, 1} ->
          Process.send_after(self(), :burst_ready, 20)
          receive do: (:burst_ready -> bytes)

        {bytes, 2} ->
          send(observer, {:burst_held, self()})
          receive do: (:continue -> bytes)

        {bytes, 0} ->
          bytes
      end)

    now = System.system_time(:second)

    origin =
      Origin.from_response(
        %{
          status: 200,
          headers: %{
            "content-length" => [Integer.to_string(byte_size(context.body))],
            "cache-control" => ["public, max-age=600"]
          },
          request: %{url: "http://source.test/image", headers: %{}}
        },
        {now, now}
      )

    context =
      restart(context,
        telemetry_prefix: [__MODULE__, context.test],
        sources: [
          path: [
            adapter: ProcessingSource,
            match: :path,
            options: [
              test: observer,
              bytes: context.body,
              stream: stream,
              origin: origin,
              copy?: true
            ]
          ]
        ],
        cache: [root: Path.join(context.root, "output")],
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000
      )

    context = %{context | url: "burst.jpg"}
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:burst_held, producer}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(producer, :continue)
    response = Task.await(task, 10_000)

    assert response.status == 200
    assert_pixels(response, context, [])
  end

  property "generated source chunking preserves originals with and without overlap", context do
    check all observed <-
                member_of([262_144, 1_048_575, 1_048_576, 1_048_577, 1_500_000, 2_097_152]),
              chunk_size <- member_of([4_096, 65_535, 65_536, 65_537, 1_048_577]),
              mode <- member_of([:overlap, :spool]),
              max_runs: 24 do
      burst_size = observed - 32_768

      <<head::binary-size(32_768), burst::binary-size(^burst_size), tail::binary>> =
        context.body

      observer = self()
      ref = make_ref()
      root = Path.join(context.root, "generated-#{System.unique_integer([:positive])}")

      stream =
        Stream.concat([
          [head, {:burst, burst}, :hold],
          Stream.unfold(tail, fn
            "" ->
              nil

            remaining ->
              size = min(chunk_size, byte_size(remaining))
              <<chunk::binary-size(^size), rest::binary>> = remaining
              {chunk, rest}
          end)
        ])
        |> Stream.flat_map(fn
          {:burst, bytes} ->
            Process.send_after(self(), ref, 20)
            receive do: (^ref -> [bytes])

          :hold ->
            send(observer, {ref, :held, self()})
            receive do: ({^ref, :continue} -> [""])

          bytes ->
            ["", bytes]
        end)

      headers = %{"cache-control" => ["public, max-age=600"]}

      headers =
        case mode do
          :overlap ->
            Map.put(headers, "content-length", [Integer.to_string(byte_size(context.body))])

          :spool ->
            headers
        end

      now = System.system_time(:second)

      origin =
        Origin.from_response(
          %{
            status: 200,
            headers: headers,
            request: %{url: "http://source.test/image", headers: %{}}
          },
          {now, now}
        )

      options =
        Caches.start!(
          telemetry_prefix: [__MODULE__, context.test],
          skip_processing_formats: [:jpeg],
          sources: [
            path: [
              adapter: ProcessingSource,
              match: :path,
              options: [
                test: observer,
                bytes: context.body,
                stream: stream,
                origin: origin,
                copy?: true
              ]
            ]
          ],
          cache: [root: Path.join(root, "output")],
          max_body_bytes: 20_000_000,
          max_input_pixels: 60_000_000
        )

      config = Caches.plug(options)

      try do
        task =
          Task.Supervisor.async_nolink(context.tasks, fn ->
            Plug.Test.conn(:get, "/w=100/src/generated.jpg") |> ImagePipe.Plug.call(config)
          end)

        assert_receive {^ref, :held, producer}, 2_000
        if mode == :overlap, do: assert_receive({:decoded, %{result: :ok, skipped: true}}, 2_000)
        send(producer, {ref, :continue})
        response = Task.await(task, 10_000)
        Caches.await_writes(options)

        assert response.status == 200
        assert response.resp_body == context.body
      after
        File.rm_rf!(root)
      end
    end
  end

  test "a truncated source is rejected after speculative decode starts", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(origin, :truncate)
    assert Task.await(task, 10_000).status == 502
    assert Path.wildcard(Path.join(context.root, "output/**/*.body")) == []
  end

  # The overlapped decode's source closes before the encode runs, so a JPEG
  # output, which is otherwise encoded straight from the source, is buffered
  # while the source is open.
  test "a JPEG output of an overlapped download is buffered before its encode", context do
    image = Image.from_binary!(complete_request(context, "w=100", "jpeg").resp_body)

    assert Image.width(image) == 100
  end

  @tag fixture: "cooking.png"
  test "PNG starts decoding before EOF and preserves buffered pixels", context do
    response = complete_request(context)
    assert_pixels(response, context, [])
  end

  test "random-access rotation preserves buffered pixels", context do
    response = complete_request(context, "w=100/-/rotate=45")
    assert_pixels(response, context, rotate: 45)
  end

  test "full-resolution arbitrary rotation can be downscaled in the same group", context do
    response = complete_request(context, "rotate=45/w=100")
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {100, 100}
    assert Image.has_alpha?(image)
    assert List.last(Image.get_pixel!(image, 0, 0)) == 0
  end

  @tag broken_cache: true
  test "cache write failures do not prevent an overlapped response", context do
    assert complete_request(context).status == 200
  end

  test "a processing timeout during overlap answers 503", context do
    pool =
      start_supervised!(
        {ImagePipe.ProcessingPool, max_concurrency: 2, processing_timeout: 60_000}
      )

    context = restart(context, Keyword.put(context.options, :processing_pool, pool))
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000

    # Fire the active job's deadline instead of waiting for it.
    [{token, %{phase: :active, deadline: deadline}}] = Map.to_list(:sys.get_state(pool).jobs)
    send(pool, {:deadline, token, :active, deadline})
    _ = :sys.get_state(pool)
    send(origin, :continue)

    assert Task.await(task, 10_000).status == 503
  end

  test "a sibling variant doesn't wait for the leader's overlapped processing", context do
    pool =
      start_supervised!({ImagePipe.ProcessingPool, max_concurrency: 1, queue_timeout: 60_000})

    options =
      context.options
      |> Keyword.put(:processing_pool, pool)
      |> put_in([:sources, :url, :options, :fetch_timeout], 1_000)

    context = restart(context, options)

    # Hold the only slot, so the leader's overlapped processing stays queued.
    test = self()

    _holder =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        ImagePipe.ProcessingPool.run(
          pool,
          fn ->
            send(test, {:holding, self()})
            receive(do: (:release -> :ok))
          end,
          []
        )
      end)

    assert_receive {:holding, holder}, 2_000
    await_stats(pool, %{active: 1, queued: 0})
    leader = Task.Supervisor.async_nolink(context.tasks, fn -> request(context, "w=100") end)
    assert_receive {:origin_held, origin}, 2_000
    await_stats(pool, %{active: 1, queued: 1})
    sibling = Task.Supervisor.async_nolink(context.tasks, fn -> request(context, "w=50") end)
    send(origin, :continue)

    # The sibling reaches the pool only once the source's work is released.
    await_stats(pool, %{active: 1, queued: 2})
    send(holder, :release)

    assert Task.await(leader, 10_000).status == 200
    assert Task.await(sibling, 10_000).status == 200
  end

  test "overlapped processing that times out in the queue answers 503 without queueing again",
       context do
    pool =
      start_supervised!({ImagePipe.ProcessingPool, max_concurrency: 1, queue_timeout: 60_000})

    context = restart(context, Keyword.put(context.options, :processing_pool, pool))
    test = self()

    _holder =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        ImagePipe.ProcessingPool.run(
          pool,
          fn ->
            send(test, {:holding, self()})
            receive(do: (:release -> :ok))
          end,
          []
        )
      end)

    assert_receive {:holding, holder}, 2_000
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    await_stats(pool, %{active: 1, queued: 1})

    # Fire the queued overlap's deadline instead of waiting for it.
    [{token, %{phase: :queued, deadline: deadline}}] =
      for {token, %{phase: :queued} = job} <- :sys.get_state(pool).jobs, do: {token, job}

    send(pool, {:deadline, token, :queued, deadline})
    _ = :sys.get_state(pool)
    send(origin, :continue)

    response = Task.await(task, 10_000)
    assert response.status == 503
    assert Plug.Conn.get_resp_header(response, "retry-after") == ["60"]
    await_stats(pool, %{active: 1, queued: 0})
    send(holder, :release)
  end

  test "an overlapped request's encode goes ahead of requests that queued after it", context do
    pool = start_supervised!({ImagePipe.ProcessingPool, max_concurrency: 1})
    context = restart(context, Keyword.put(context.options, :processing_pool, pool))
    test = self()

    waiter = fn label ->
      Task.Supervisor.async_nolink(context.tasks, fn ->
        ImagePipe.ProcessingPool.run(
          pool,
          fn ->
            send(test, {:holding, label, self()})
            receive(do: (:release -> :ok))
          end,
          []
        )
      end)
    end

    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    await_stats(pool, %{active: 1, queued: 0})

    first = waiter.(:first)
    await_stats(pool, %{active: 1, queued: 1})
    later = waiter.(:later)
    await_stats(pool, %{active: 1, queued: 2})

    # The decode's turn ends with the download, and the first waiter takes
    # the slot. The encode then waits ahead of the later one.
    send(origin, :continue)
    assert_receive {:holding, :first, first_worker}, 5_000
    await_stats(pool, %{active: 1, queued: 2})
    send(first_worker, :release)

    # It finishes while the later waiter is still held, so it didn't queue
    # behind it.
    assert Task.await(task, 10_000).status == 200
    assert_receive {:holding, :later, later_worker}, 5_000
    send(later_worker, :release)
    assert Task.await(first) == :ok
    assert Task.await(later) == :ok
  end

  test "request cancellation terminates speculative processing", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, _}, 2_000
    assert_receive {:decode_worker, worker}, 2_000
    monitor = Process.monitor(worker)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
  end

  @tag fixture: "cooking.png"
  test "early crop completion still waits for the entire original", context do
    task =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        request(context, "crop=32,32/anchor=top-left")
      end)

    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decode_worker, worker}, 2_000
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, reason}, 2_000
    assert reason in [:normal, :noproc]
    assert Task.yield(task, 0) == nil
    send(origin, :continue)
    assert Task.await(task, 10_000).status == 200
  end

  test "pixel limits still reject a speculative candidate", context do
    context = restart(context, Keyword.put(context.options, :max_input_pixels, 100))
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{error: :input_limit}}, 2_000
    send(origin, :continue)
    assert Task.await(task, 10_000).status == 413
  end

  test "watermarked requests wait for the full source instead of overlapping", context do
    File.mkdir_p!(context.root)
    mark = Image.new!(20, 20, color: [255, 0, 0]) |> Image.write!(:memory, suffix: ".png")
    File.write!(Path.join(context.root, "mark.png"), mark)

    context =
      restart(context,
        telemetry_prefix: [__MODULE__, context.test],
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000,
        sources: [
          url: [
            adapter: HTTP,
            match: [scheme: ["http", "https"]],
            options: [
              allowed_hosts: [URI.parse(context.url).authority],
              address_policy: [allow_loopback: true]
            ]
          ],
          files: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: context.root, root_id: "overlap"]
          ]
        ],
        cache: [root: Path.join(context.root, "output")],
        watermarks: %{logo: [source: "mark.png"]}
      )

    task =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        request(context, "w=100/wm=logo/wm-at=top-left")
      end)

    assert_receive {:origin_held, origin}, 2_000
    refute_receive {:decoded, _metadata}, 200
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert Enum.map(Image.get_pixel!(image, 5, 5), &round/1) == [255, 0, 0]
  end

  test "low-priority requests wait for the full source instead of overlapping", context do
    task =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(context, "w=100/priority=low") end)

    assert_receive {:origin_held, origin}, 2_000
    refute_receive {:decoded, _metadata}, 200
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    assert_pixels(response, context, [])
  end

  defp complete_request(context, options \\ "w=100", format \\ "png") do
    task =
      Task.Supervisor.async_nolink(context.tasks, fn -> request(context, options, format) end)

    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    response
  end

  defp reference_config,
    do: ImagePipe.config(max_body_bytes: 20_000_000, max_input_pixels: 60_000_000)

  defp assert_pixels(response, context, operations) do
    builder =
      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 100])
      |> append_group(operations)
      |> ImagePipe.URL.output(format: :png)

    assert {:ok, reference} = ImagePipe.run(reference_config(), builder, {:binary, context.body})

    assert VipsImage.write_to_binary(Image.from_binary!(response.resp_body)) ==
             VipsImage.write_to_binary(Image.from_binary!(reference.data))
  end

  defp append_group(builder, []), do: builder
  defp append_group(builder, operations), do: ImagePipe.URL.group(builder, operations)

  defp request(context, options \\ "w=100", format \\ "png") do
    response =
      Plug.Test.conn(:get, "/#{options}/format=#{format}/src/#{context.url}/image")
      |> ImagePipe.Plug.call(context.config)

    Caches.await_writes(context.options)
    response
  end

  # Replaces the setup's instance with one running `options` on the same caches.
  defp await_stats(pool, expected, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      Map.take(ImagePipe.ProcessingPool.stats(pool), Map.keys(expected)) == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "pool never reached #{inspect(expected)}: #{inspect(ImagePipe.ProcessingPool.stats(pool))}"
        )

      true ->
        receive do
        after
          10 -> await_stats(pool, expected, deadline)
        end
    end
  end

  defp restart(context, options) do
    stop_supervised!(Caches.instance(context.options))
    options = Caches.start!(options)
    %{context | options: options, config: Caches.plug(options)}
  end
end

defmodule ImagePipe.API.SourceOverlapWireTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Origin
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
      File.write!(Path.join(root, "input"), "unavailable")
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

    config =
      ImagePipe.Plug.init(
        telemetry_prefix: prefix,
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000,
        sources: [
          url: [
            adapter: HTTP,
            match: [scheme: ["http", "https"]],
            options: [allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]]
          ]
        ],
        cache: {FileSystem, root: Path.join(root, "output")},
        input_cache: {FileSystem, root: Path.join(root, "input")},
        http_cache: :auto
      )

    tasks = start_supervised!(Task.Supervisor)
    %{config: config, origin: origin, url: url, tasks: tasks, body: body, root: root}
  end

  test "opens progressive JPEG before EOF, preserves pixels, and reuses cached output", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    assert Path.wildcard(Path.join(context.root, "input/**/*.body")) == []
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    assert {:ok, image} = Image.from_binary(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {100, 150}
    [original] = Path.wildcard(Path.join(context.root, "input/**/*.body"))
    assert File.read!(original) == context.body

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
    config = Keyword.put(context.config, :skip_processing_formats, [:jpeg])

    task =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        Plug.Test.conn(:get, "/w=100/src/#{context.url}/image") |> ImagePipe.Plug.call(config)
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

    config =
      ImagePipe.Plug.init(
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
        cache: {FileSystem, root: Path.join(context.root, "output")},
        input_cache: {FileSystem, root: Path.join(context.root, "input")},
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000
      )

    response =
      Plug.Test.conn(:get, "/w=100/format=png/src/empty.jpg") |> ImagePipe.Plug.call(config)

    assert response.status == 200
    assert_pixels(response, context, [])
    assert_receive {:closed, ["empty.jpg"]}
  end

  test "overlap selected after a large burst preserves the original and cached pixels", context do
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

    config =
      ImagePipe.Plug.init(
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
        cache: {FileSystem, root: Path.join(context.root, "output")},
        input_cache: {FileSystem, root: Path.join(context.root, "input")},
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000
      )

    context = %{context | config: config, url: "burst.jpg"}
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:burst_held, producer}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(producer, :continue)
    response = Task.await(task, 10_000)

    assert response.status == 200
    [original] = Path.wildcard(Path.join(context.root, "input/**/*.body"))
    assert File.stat!(original).size == byte_size(context.body)
    assert File.read!(original) == context.body
    assert_pixels(response, context, [])

    assert_receive {:fetch, ["burst.jpg", "image"], _}
    cached_source = request(context, "w=100/-/rotate=45")
    assert cached_source.status == 200
    assert_pixels(cached_source, context, rotate: 45)
    refute_received {:fetch, _, _}
  end

  test "a truncated source is rejected after speculative decode starts", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(origin, :truncate)
    assert Task.await(task, 10_000).status == 502
    assert Path.wildcard(Path.join(context.root, "input/**/*.body")) == []
    assert Path.wildcard(Path.join(context.root, "output/**/*.body")) == []
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

  test "request cancellation terminates speculative processing", context do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context) end)
    assert_receive {:origin_held, _}, 2_000
    assert_receive {:decode_worker, worker}, 2_000
    monitor = Process.monitor(worker)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
  end

  @tag fixture: "cooking.png"
  test "early crop completion still stages the entire original before publishing", context do
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
    assert Path.wildcard(Path.join(context.root, "input/**/*.body")) == []
    send(origin, :continue)
    assert Task.await(task, 10_000).status == 200
    [original] = Path.wildcard(Path.join(context.root, "input/**/*.body"))
    assert File.read!(original) == context.body
  end

  test "pixel limits still reject a speculative candidate", context do
    context = %{context | config: Keyword.put(context.config, :max_input_pixels, 100)}
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

    config =
      ImagePipe.Plug.init(
        telemetry_prefix: [__MODULE__, context.test],
        max_body_bytes: 20_000_000,
        max_input_pixels: 60_000_000,
        sources: [
          url: [
            adapter: HTTP,
            match: [scheme: ["http", "https"]],
            options: [allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]]
          ],
          files: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: context.root, root_id: "overlap"]
          ]
        ],
        cache: {FileSystem, root: Path.join(context.root, "output")},
        input_cache: {FileSystem, root: Path.join(context.root, "input")},
        watermarks: %{logo: [source: "mark.png"]}
      )

    task =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        request(%{context | config: config}, "w=100/wm=logo/wm-at=top-left")
      end)

    assert_receive {:origin_held, origin}, 2_000
    refute_receive {:decoded, _metadata}, 200
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert Enum.map(Image.get_pixel!(image, 5, 5), &round/1) == [255, 0, 0]
  end

  defp complete_request(context, options \\ "w=100") do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context, options) end)
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

  defp request(context, options \\ "w=100") do
    Plug.Test.conn(:get, "/#{options}/format=png/src/#{context.url}/image")
    |> ImagePipe.Plug.call(context.config)
  end
end

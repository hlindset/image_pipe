defmodule ImagePipe.API.SourceOverlapWireTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Test.PacedSourceOrigin
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
          url: {HTTP, allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]}
        ],
        cache: {FileSystem, root: Path.join(root, "output")},
        input_cache: {FileSystem, root: Path.join(root, "input")},
        http_cache: [mode: :enabled]
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

    reference =
      ImagePipe.config(max_body_bytes: 20_000_000, max_input_pixels: 60_000_000)
      |> ImagePipe.new()
      |> ImagePipe.group(resize: [width: 100])
      |> ImagePipe.output(format: :png)
      |> ImagePipe.run({:binary, context.body})

    assert {:ok, reference} = reference

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

  defp complete_request(context, options \\ "w=100") do
    task = Task.Supervisor.async_nolink(context.tasks, fn -> request(context, options) end)
    assert_receive {:origin_held, origin}, 2_000
    assert_receive {:decoded, %{result: :ok}}, 2_000
    send(origin, :continue)
    response = Task.await(task, 10_000)
    assert response.status == 200
    response
  end

  defp assert_pixels(response, context, operations) do
    assert {:ok, reference} =
             ImagePipe.config(max_body_bytes: 20_000_000, max_input_pixels: 60_000_000)
             |> ImagePipe.new()
             |> ImagePipe.group(resize: [width: 100])
             |> append_group(operations)
             |> ImagePipe.output(format: :png)
             |> ImagePipe.run({:binary, context.body})

    assert VipsImage.write_to_binary(Image.from_binary!(response.resp_body)) ==
             VipsImage.write_to_binary(Image.from_binary!(reference.data))
  end

  defp append_group(builder, []), do: builder
  defp append_group(builder, operations), do: ImagePipe.group(builder, operations)

  defp request(context, options \\ "w=100") do
    Plug.Test.conn(:get, "/#{options}/format=png/src/#{context.url}/image")
    |> ImagePipe.Plug.call(context.config)
  end
end

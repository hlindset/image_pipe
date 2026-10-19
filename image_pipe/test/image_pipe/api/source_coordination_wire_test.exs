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
      fn _, _, _, test -> send(test, {:generated, self()}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach({handler, :generated}) end)
    on_exit(fn -> :telemetry.detach(handler) end)

    %{root: root, prefix: prefix, tasks: start_supervised!(Task.Supervisor)}
  end

  def event(_event, _measurements, metadata, test), do: send(test, {:coordination, metadata})

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
      assert_receive {:coordination, %{pool: :output, result: :waiting}}
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
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
    send(leader, :continue)

    original = Task.await(first)
    assert Task.await(second).resp_body == original.resp_body
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

    first = async(context, fn -> request(mount, 12) end)
    assert_receive {:streaming, leader}
    second = async(context, fn -> request(mount, 12) end)
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
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
    await_waiter()
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
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
    send(leader, :continue)
    assert_receive {:streaming, ^leader}
    assert_receive {:fetch, ["blocked"], other}
    send(other, :continue)
    assert_receive {:streaming, ^other}

    for worker <- [leader, other], do: send(worker, :continue)
    assert Task.await(first).status == 200
    assert Task.await(second).status == 200
  end

  # Each download sends its process once its first bytes are read, and holds
  # the rest until that process gets `:continue`.
  defp start(context, options) do
    {origin, caches} = Keyword.pop(options, :origin)
    test = self()

    stream =
      Stream.map([@image], fn bytes ->
        send(test, {:streaming, self()})
        receive do: (:continue -> bytes)
      end)

    source = [test: test, bytes: @image, copy?: true, stream: stream, origin: origin]

    [
      telemetry_prefix: context.prefix,
      sources: [path: [adapter: ProcessingSource, match: :path, options: source]]
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

  defp request(mount, width, source \\ "original"),
    do: ImagePipe.Plug.call(conn(:get, "/w=#{width}/format=png/src/#{source}"), mount)

  defp await_waiter do
    waiting? =
      ImagePipe.Cache.Work
      |> :sys.get_state()
      |> Map.fetch!(:locks)
      |> Enum.any?(fn {_key, lock} -> lock.waiters != [] end)

    unless waiting?, do: await_waiter()
  end
end

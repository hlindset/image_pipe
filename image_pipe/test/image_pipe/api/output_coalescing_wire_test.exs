defmodule ImagePipe.API.OutputCoalescingWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Execution
  alias ImagePipe.Execution.{Inputs, Output}
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Test.CacheObserver
  alias ImagePipe.Test.Caches
  alias ImagePipe.Test.ProcessingSource

  # These tests coordinate who generates an output, not what it looks like, so
  # a small image keeps each generation short on a busy CI runner.
  @image Image.new!(64, 48, color: :red) |> Image.write!(:memory, suffix: ".jpg")
  # A promoted waiter's source closes only after it generates the whole output.
  @generation_timeout 10_000

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(handler, prefix ++ [:cache, :coordination], &__MODULE__.event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    options =
      CacheObserver.observe(
        processing_pool: pool,
        telemetry_prefix: prefix,
        sources: [
          path: [adapter: ProcessingSource, match: :path, options: [test: self(), bytes: @image]]
        ]
      )

    %{
      tasks: tasks,
      pool: pool,
      options: options,
      mount: Caches.plug(options),
      instance: Caches.instance(options)
    }
  end

  def event(_event, _measurements, metadata, test), do: send(test, {:coordination, metadata})

  test "matching Plug and Elixir misses share one generation across terminals", context do
    mount = context.mount

    for {terminal, path} <- [
          image: "format=jpeg",
          info: "output=info",
          blurhash: "output=blurhash",
          lqip_css: "output=lqip-css"
        ] do
      leader = async(context, fn -> request(mount, path) end)
      assert_receive {:fetch, ["blocked"], worker}

      follower = async(context, fn -> request(mount, path) end)
      assert_receive {:coordination, %{pool: :output, result: :waiting}}

      builder =
        ImagePipe.URL.new() |> ImagePipe.URL.output(output_options(terminal))

      elixir =
        async(context, fn -> ImagePipe.run(context.instance, builder, {:source, "blocked"}) end)

      assert_receive {:coordination, %{pool: :output, result: :waiting}}

      assert %{active: 1, queued: 0} = ProcessingPool.stats(context.pool)
      send(worker, :continue)
      original = Task.await(leader)
      assert original.status == 200
      result = Task.await(follower)
      assert result.status == 200
      assert result.resp_body == original.resp_body
      assert {:ok, _} = Task.await(elixir)
      refute_received {:fetch, ["blocked"], _}
    end
  end

  test "identical requests share one generation while 64 other images wait for a turn",
       context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 128}, id: :deep)
    options = context.options |> Keyword.put(:processing_pool, pool) |> CacheObserver.observe()
    mount = Caches.plug(options)

    others =
      for index <- 1..64,
          do: async(context, fn -> request(mount, "format=jpeg", "other-#{index}") end)

    assert_receive {:fetch, ["other-" <> _], first_worker}

    for _ <- 1..64, do: assert_receive({:coordination, %{pool: :output, result: :acquired}})

    leader = async(context, fn -> request(mount, "format=jpeg") end)
    assert_receive {:coordination, %{pool: :output, result: :acquired}}
    follower = async(context, fn -> request(mount, "format=jpeg") end)
    assert_receive {:coordination, %{pool: :output, result: :waiting}}

    send(first_worker, :continue)

    for _ <- 1..64 do
      assert_receive {:fetch, [_], worker}, @generation_timeout
      send(worker, :continue)
    end

    original = Task.await(leader, @generation_timeout)
    assert original.status == 200
    assert Task.await(follower, @generation_timeout).resp_body == original.resp_body
    refute_received {:fetch, ["blocked"], _}
    for task <- others, do: assert(Task.await(task, @generation_timeout).status == 200)
  end

  test "without output caching identical requests use ordinary admission", context do
    mount =
      ImagePipe.Plug.init(
        Keyword.put_new(Keyword.delete(context.options, :cache), :allow_unsigned, true)
      )

    leader = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    assert request(mount, "output=info").status == 503
    send(worker, :continue)
    assert Task.await(leader).status == 200
    refute_received {:coordination, %{pool: :output}}
  end

  test "a missing committed entry falls back to generation once", context do
    mount = context.mount
    root = context.options |> Keyword.fetch!(:cache) |> Keyword.fetch!(:root)
    handler = make_ref()

    # Removes each entry as soon as it is committed, before followers read it.
    :telemetry.attach(
      handler,
      context.options[:telemetry_prefix] ++ [:cache, :write, :stop],
      fn _event, _measurements, %{cache_key: hash}, root ->
        {:ok, %{meta_path: meta_path}} = FileSystem.paths_from_hash(hash, root: root)
        File.rm!(meta_path)
      end,
      root
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    leader = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    follower = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
    send(worker, :continue)
    assert Task.await(leader).status == 200
    assert_receive {:fetch, ["blocked"], second}
    send(second, :continue)
    assert Task.await(follower).status == 200
    refute_received {:fetch, ["blocked"], _}
  end

  test "different cache instances and output variants do not join", context do
    mount = context.mount
    other = context.options |> CacheObserver.observe() |> Caches.plug()

    leader = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    assert request(other, "output=info").status == 503
    assert request(mount, "format=png").status == 503
    refute_received {:coordination, %{pool: :output, result: :waiting}}
    send(worker, :continue)
    assert Task.await(leader).status == 200
  end

  test "a leader's entry is stored when its encode ends, whatever its client does",
       context do
    test = self()

    for action <- [:cancel, :disconnect, :complete] do
      # A fresh cache per round, so each round misses.
      options = CacheObserver.observe(context.options)
      config = instance_options(options)
      mount = Caches.plug(options)

      leader =
        async(context, fn ->
          builder = ImagePipe.URL.new() |> ImagePipe.URL.output(format: :jpeg)
          {:ok, request} = ImagePipe.Plan.to_spec(builder.plan)
          {:ok, policy} = ImagePipe.Processing.prepare(request, config, "")
          {:ok, source, config} = ImagePipe.Source.from_input({:source, "blocked"}, config)

          {:ok, execution} =
            Execution.prepare(
              request,
              source,
              [],
              policy,
              %Inputs{},
              config
            )

          {:ok, output} = Execution.open(execution)
          send(test, :prepared)

          receive do
            :complete -> Output.consume(output)
            :cancel -> :ok
          end

          Execution.close_output(output)
          Execution.close(execution)
        end)

      assert_receive {:fetch, ["blocked"], worker}
      send(worker, :continue)
      assert_receive :prepared
      assert_receive {:cache_put, _hash, _body}, @generation_timeout
      assert_receive {:closed, ["blocked"]}, @generation_timeout
      assert %{active: 0, queued: 0} = ProcessingPool.stats(context.pool)

      case action do
        :disconnect ->
          Task.shutdown(leader, :brutal_kill)

        _ ->
          send(leader.pid, action)
          Task.await(leader, @generation_timeout)
      end

      assert request(mount, "format=jpeg").status == 200
      refute_received {:fetch, ["blocked"], _}
    end
  end

  @tag capture_log: true
  @tag :file_permissions
  test "cache write failures and rejected entries leave followers able to generate", context do
    for {failure, path} <- [unwritable: "format=jpeg", too_large: "output=info"] do
      mount = Caches.plug(failing_cache(context.options, failure))
      leader = async(context, fn -> request(mount, path) end)
      assert_receive {:fetch, ["blocked"], worker}
      follower = async(context, fn -> request(mount, path) end)
      assert_receive {:coordination, %{pool: :output, result: :waiting}}
      send(worker, :continue)
      assert Task.await(leader).status == 200
      assert_receive {:fetch, ["blocked"], second}
      send(second, :continue)
      assert Task.await(follower).status == 200
    end
  end

  test "a leader whose output won't be stored releases its followers at once", context do
    test = self()
    pool = start_supervised!({ProcessingPool, max_concurrency: 2}, id: :wide_pool)

    options =
      context.options
      |> Keyword.put(:processing_pool, pool)
      |> CacheObserver.observe(max_body_bytes: 0)

    config = instance_options(options)
    mount = Caches.plug(options)

    leader =
      async(context, fn ->
        builder = ImagePipe.URL.new() |> ImagePipe.URL.output(format: :jpeg)
        {:ok, request} = ImagePipe.Plan.to_spec(builder.plan)
        {:ok, policy} = ImagePipe.Processing.prepare(request, config, "")
        {:ok, source, options} = ImagePipe.Source.from_input({:source, "blocked"}, config)
        {:ok, execution} = Execution.prepare(request, source, [], policy, %Inputs{}, options)
        {:ok, output} = Execution.open(execution)
        send(test, :prepared)

        receive do
          :complete -> Output.consume(output)
        end

        Execution.close_output(output)
        Execution.close(execution)
      end)

    assert_receive {:fetch, ["blocked"], worker}
    send(worker, :continue)
    assert_receive :prepared

    follower = async(context, fn -> request(mount, "format=jpeg") end)
    assert_receive {:fetch, ["blocked"], second}, @generation_timeout
    send(second, :continue)
    assert Task.await(follower, @generation_timeout).status == 200

    send(leader.pid, :complete)
    Task.await(leader, @generation_timeout)
  end

  test "a failed leader does not impose its safety limits on followers", context do
    builder = ImagePipe.URL.new() |> ImagePipe.URL.output(terminal: :info)

    leader =
      async(context, fn ->
        ImagePipe.run(context.instance, builder, {:source, "blocked"}, max_input_pixels: 1)
      end)

    assert_receive {:fetch, ["blocked"], worker}
    follower = async(context, fn -> request(context.mount, "output=info") end)
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
    send(worker, :continue)
    assert {:error, {:input_limit, _reason}} = Task.await(leader)
    assert_receive {:fetch, ["blocked"], second}
    send(second, :continue)
    assert Task.await(follower).status == 200
  end

  defp failing_cache(options, :too_large), do: CacheObserver.observe(options, max_body_bytes: 0)

  defp failing_cache(options, :unwritable) do
    options = CacheObserver.observe(options)
    root = options |> Keyword.fetch!(:cache) |> Keyword.fetch!(:root)
    File.chmod!(root, 0o500)
    on_exit(fn -> File.chmod(root, 0o700) end)
    options
  end

  # The options requests through the instance for `options` run with.
  defp instance_options(options),
    do: Caches.options(options)

  defp async(context, fun), do: Task.Supervisor.async_nolink(context.tasks, fun)

  defp request(mount, path, source \\ "blocked"),
    do: ImagePipe.Plug.call(conn(:get, "/#{path}/src/#{source}"), mount)

  defp output_options(:image), do: [format: :jpeg]
  defp output_options(terminal), do: [terminal: terminal]
end

defmodule ImagePipe.API.OutputCoalescingWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Execution
  alias ImagePipe.Execution.{Inputs, Output}
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias ImagePipe.Test.ProcessingSource
  alias ImagePipe.Test.RaisingOpenCache

  @image File.read!("priv/static/images/beach.jpg")

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(handler, prefix ++ [:cache, :coordination], &__MODULE__.event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    options = [
      processing_pool: pool,
      telemetry_prefix: prefix,
      cache: {CacheProbe, store: :ets.new(:outputs, [:set, :public])},
      sources: [path: {ProcessingSource, test: self(), bytes: @image}]
    ]

    %{tasks: tasks, pool: pool, config: ImagePipe.config(options), options: options}
  end

  def event(_event, _measurements, metadata, test), do: send(test, {:coordination, metadata})

  test "matching Plug and Elixir misses share one generation across terminals", context do
    mount = ImagePipe.Plug.init(config: context.config)

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
        context.config |> ImagePipe.new() |> ImagePipe.output(output_options(terminal))

      elixir = async(context, fn -> ImagePipe.run(builder, {:source, "blocked"}) end)
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

  test "without output caching identical requests use ordinary admission", context do
    mount = ImagePipe.Plug.init(Keyword.delete(context.options, :cache))
    leader = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    assert request(mount, "output=info").status == 503
    send(worker, :continue)
    assert Task.await(leader).status == 200
    refute_received {:coordination, %{pool: :output}}
  end

  test "a missing committed entry falls back to generation once", context do
    mount =
      ImagePipe.Plug.init(Keyword.put(context.options, :cache, {CacheProbe, scope: make_ref()}))

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
    mount = ImagePipe.Plug.init(config: context.config)

    other =
      ImagePipe.Plug.init(
        Keyword.put(
          context.options,
          :cache,
          {CacheProbe, store: :ets.new(:other, [:set, :public])}
        )
      )

    leader = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    assert request(other, "output=info").status == 503
    assert request(mount, "format=png").status == 503
    refute_received {:coordination, %{pool: :output, result: :waiting}}
    send(worker, :continue)
    assert Task.await(leader).status == 200
  end

  test "stream ownership lasts through commit and promotes a waiter after cancellation",
       context do
    test = self()

    for action <- [:cancel, :disconnect, :complete] do
      mount = ImagePipe.Plug.init(config: context.config)

      leader =
        async(context, fn ->
          builder = context.config |> ImagePipe.new() |> ImagePipe.output(format: :jpeg)
          {:ok, request} = ImagePipe.Plan.to_request(builder.plan, "")
          config = builder.config.options
          {:ok, policy} = ImagePipe.Processing.prepare(request, config, "")
          {:ok, source, config} = ImagePipe.Source.from_input({:source, "blocked"}, config)

          {:ok, execution} =
            Execution.prepare(
              request,
              source,
              policy,
              Inputs.new!([]),
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
      follower = async(context, fn -> request(mount, "format=jpeg") end)
      assert_receive {:coordination, %{pool: :output, result: :waiting}}
      assert %{active: 1, queued: 0} = ProcessingPool.stats(context.pool)
      refute_received {:closed, ["blocked"]}

      case action do
        :disconnect ->
          Task.shutdown(leader, :brutal_kill)

        _ ->
          send(leader.pid, action)
          Task.await(leader)
      end

      assert_receive {:closed, ["blocked"]}

      unless action == :complete do
        assert_receive {:fetch, ["blocked"], replacement}
        send(replacement, :continue)
        assert_receive {:closed, ["blocked"]}
      end

      assert Task.await(follower).status == 200
      refute_received {:fetch, ["blocked"], _}
      {CacheProbe, cache_options} = Keyword.fetch!(context.options, :cache)
      :ets.delete_all_objects(Keyword.fetch!(cache_options, :store))
    end
  end

  @tag capture_log: true
  test "cache write failures and rejected entries leave followers able to generate", context do
    for {cache, path} <- [
          {{RaisingOpenCache, test_pid: self()}, "format=jpeg"},
          {{CacheProbe, max_body_bytes: 0, scope: make_ref()}, "output=info"}
        ] do
      mount = ImagePipe.Plug.init(Keyword.put(context.options, :cache, cache))
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

  test "a failed leader does not impose its safety limits on followers", context do
    mount = ImagePipe.Plug.init(config: context.config)
    restricted = ImagePipe.Plug.init(Keyword.put(context.options, :max_input_pixels, 1))
    leader = async(context, fn -> request(restricted, "output=info") end)
    assert_receive {:fetch, ["blocked"], worker}
    follower = async(context, fn -> request(mount, "output=info") end)
    assert_receive {:coordination, %{pool: :output, result: :waiting}}
    send(worker, :continue)
    assert Task.await(leader).status == 413
    assert_receive {:fetch, ["blocked"], second}
    send(second, :continue)
    assert Task.await(follower).status == 200
  end

  defp async(context, fun), do: Task.Supervisor.async_nolink(context.tasks, fun)
  defp request(mount, path), do: ImagePipe.Plug.call(conn(:get, "/#{path}/src/blocked"), mount)
  defp output_options(:image), do: [format: :jpeg]
  defp output_options(terminal), do: [terminal: terminal]
end

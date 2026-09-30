defmodule ImagePipe.Delivery.ProcessingControlsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:processing, :execute, :stop],
      fn _, _, metadata, pid -> send(pid, {:processing_stopped, metadata.result}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{tasks: tasks, prefix: prefix}
  end

  test "retains a slot until EOF cleanup and explicit cancellation", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    for action <- [:eof, :cancel] do
      build = fn pump ->
        try do
          pump.(["one", "two"], "image/jpeg", resolved(), nil)
        after
          send(test, :cleanup)
        end
      end

      assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
      assert %{active: 1} = ProcessingPool.stats(pool)

      assert {:error, {:processing, :overloaded}} =
               ProcessingPool.run(pool, fn -> flunk() end, [])

      case action do
        :eof ->
          assert stream.next.() == {:chunk, "two"}
          assert stream.next.() == :done

        :cancel ->
          assert stream.cancel.() == :ok
      end

      assert_received :cleanup
      assert %{active: 0} = ProcessingPool.stats(pool)
    end
  end

  test "an idle prepared stream retains the processing timeout for its next pull", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, processing_timeout: 40})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    build = fn pump -> pump.(["one", "two"], "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
    assert stream.first_chunk == "one"
    assert_receive {:processing_stopped, :timeout}
    assert stream.next.() == {:error, {:processing, :timeout}}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "owner death gracefully cancels prepared streams and releases admission", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]
    test = self()

    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        build = fn pump ->
          try do
            pump.(["one", "two"], "image/jpeg", resolved(), nil)
          after
            send(test, :cleanup)
          end
        end

        {:ok, _stream} = Delivery.stream(self(), build, nil, config)
        send(test, :prepared)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :prepared
    Task.shutdown(owner, :brutal_kill)
    assert_receive :cleanup
    assert_receive {:processing_stopped, :cancelled}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  test "failure after the first chunk releases the slot", context do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1})
    config = [processing_pool: pool, telemetry_prefix: context.prefix]

    source =
      Stream.map(["one", "two"], fn
        "one" -> "one"
        "two" -> raise "encode failure"
      end)

    build = fn pump -> pump.(source, "image/jpeg", resolved(), nil) end
    assert {:ok, stream} = Delivery.stream(self(), build, nil, config)
    assert {:error, _} = stream.next.()
    assert_receive {:processing_stopped, :processing_error}
    assert %{active: 0} = ProcessingPool.stats(pool)
  end

  defp resolved do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end
end

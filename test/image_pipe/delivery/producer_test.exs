defmodule ImagePipe.Delivery.ProducerTest do
  @moduledoc """
  `ImagePipe.Delivery.Producer`'s demand protocol, driven directly with a
  synthetic `build_fun` — the level at which chunk demand, halt-time stream
  finalization, and post-first-chunk error tagging are decided.

  `ImagePipe.Delivery.ContractTest` covers the same producer through the
  public `Delivery.stream/5` surface; these cases need the raw
  `{:next, …}`/`{:halt, …}` protocol, so they use the test-support client.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.Delivery.Producer
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Test.Delivery.ProducerClient

  @event_target __MODULE__.StreamEvents

  defp resolved_output do
    %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  defp build_fun(stream) do
    fn pump -> pump.(stream, "image/jpeg", resolved_output(), nil) end
  end

  defp cleanup_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {["first chunk"], :second}
        :second -> {["second chunk"], :done}
        :done -> {:halt, :done}
      end,
      fn state -> notify({:stream_finalized, state}) end
    )
  end

  defp raising_after_first_chunk_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {["first chunk"], :raise}
        :raise -> raise "boom after first chunk"
      end,
      fn _state -> :ok end
    )
  end

  defp source_error_after_first_chunk_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {["first chunk"], :raise}
        :raise -> raise StreamError, reason: :stream_exception
      end,
      fn _state -> :ok end
    )
  end

  defp blocking_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first ->
          {["first chunk"], :second}

        :second ->
          notify({:producer_blocked, self()})

          receive do
            :continue -> {["second chunk"], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn state -> notify({:blocking_stream_finalized, state}) end
    )
  end

  defp notify(message) do
    if target = Process.whereis(@event_target), do: send(target, message)
  end

  setup do
    Process.flag(:trap_exit, true)

    if Process.whereis(@event_target), do: Process.unregister(@event_target)
    Process.register(self(), @event_target)

    on_exit(fn ->
      if Process.whereis(@event_target), do: Process.unregister(@event_target)
    end)

    :ok
  end

  defp start_producer(stream) do
    start_supervised!(%{
      id: {Producer, make_ref()},
      start: {Producer, :start_link, [build_fun(stream), nil]},
      restart: :temporary,
      shutdown: 2_000,
      type: :worker
    })
  end

  test "producer returns first chunk, later chunks, and done on demand" do
    producer = start_producer(["first chunk", "second chunk"])
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", resolved_output, _debug}} =
             ProducerClient.next(producer)

    assert resolved_output.format == :jpeg
    assert {:ok, {:chunk, "second chunk"}} = ProducerClient.next(producer)
    assert {:ok, :done} = ProducerClient.next(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer halt runs the suspended stream cleanup callback when idle" do
    producer = start_producer(cleanup_stream())
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", _resolved_output, _debug}} =
             ProducerClient.next(producer)

    assert :ok = ProducerClient.halt(producer)
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer returns post-first-chunk encoder errors" do
    producer = start_producer(raising_after_first_chunk_stream())
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", _resolved_output, _debug}} =
             ProducerClient.next(producer)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             ProducerClient.next(producer)

    assert is_list(stacktrace)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  # The taxonomy rule the framework's runner depends on: a Source.StreamError
  # escaping the pumped stream keeps the SOURCE phase, so it maps to the
  # source's domain status rather than degrading to the 500 an {:encode, _}
  # tag would produce. Ported from the framework's own session tests, which
  # pinned the same rule before the delivery topology was unified.
  test "source stream errors during encoder reduction keep source phase" do
    producer = start_producer(source_error_after_first_chunk_stream())
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", _resolved_output, _debug}} =
             ProducerClient.next(producer)

    assert {:error, {:source, :stream_exception}} = ProducerClient.next(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "source stream errors before the first chunk keep source phase" do
    producer =
      start_producer(Stream.map([:raise], fn _ -> raise StreamError, reason: :body_too_large end))

    ref = Process.monitor(producer)

    assert {:error, {:source, :body_too_large}} = ProducerClient.next(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer can be stopped while a demand is blocked" do
    producer = start_producer(blocking_stream())
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", _resolved_output, _debug}} =
             ProducerClient.next(producer)

    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:next_result, ProducerClient.next(producer, 5_000)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:producer_blocked, ^producer}
    Process.exit(producer, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^producer, :shutdown}
    assert_receive {:next_result, {:error, {:producer, {:exit, :shutdown}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  defp start_test_process(fun) when is_function(fun, 0) do
    supervisor =
      start_supervised!(%{
        id: {Task.Supervisor, make_ref()},
        start: {Task.Supervisor, :start_link, [[name: nil]]},
        restart: :temporary,
        type: :supervisor
      })

    {:ok, pid} = Task.Supervisor.start_child(supervisor, fun)
    pid
  end
end

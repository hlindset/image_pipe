defmodule ImagePipe.Delivery.DeliveryLifecycleTest do
  @moduledoc """
  `ImagePipe.Delivery`'s session lifecycle, driven with synthetic `build_fun`s:
  owner death, explicit cancel, prepare failure, cancel idempotence, and the
  graceful-halt bracket-cleanup guarantee.

  These cases were ported from the retired supervised-session tests. Ownership
  is a `Process.monitor` on the conn owner now, so an owner-death case spawns a
  process that calls `Delivery.stream/5` (which requires `self()` as owner) and
  hands the `%PreparedStream{}` back — the `next`/`cancel` closures are plain
  `GenServer.call`s and work from any process.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response, as: PlanResponse

  @event_target __MODULE__.StreamEvents

  setup do
    if Process.whereis(@event_target), do: Process.unregister(@event_target)
    Process.register(self(), @event_target)

    on_exit(fn ->
      if Process.whereis(@event_target), do: Process.unregister(@event_target)
    end)

    :ok
  end

  defp notify(message) do
    if target = Process.whereis(@event_target), do: send(target, message)
  end

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

  # A dialect's `build_fun` wraps its pump call in brackets (fetch/decode) whose
  # `after` must run exactly once. This stands in for that bracket.
  defp bracketed_build_fun(stream) do
    fn pump ->
      try do
        pump.(stream, "image/jpeg", resolved_output(), nil)
      after
        notify(:bracket_cleanup)
      end
    end
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

  # Blocks inside the reduce until released — a producer wedged mid-chunk,
  # which cannot observe a graceful halt message.
  defp gated_second_chunk_stream do
    Stream.resource(
      fn -> :first end,
      fn
        :first ->
          {["first chunk"], :second}

        :second ->
          notify({:before_second_chunk, self()})

          receive do
            :continue -> {["second chunk"], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _state -> :ok end
    )
  end

  # `Delivery.stream/5` monitors the coordinator from the owner, so when the
  # test process is the owner this DOWN is the deterministic "session is gone"
  # signal — without it, a call racing a stopping coordinator sees
  # `{:exit, :normal}` rather than `:noproc`.
  defp await_session_gone do
    assert_receive {:DOWN, _ref, :process, _coordinator, _reason}, 2_000
  end

  # Starts a delivery owned by a separate process, so owner death is testable.
  # `spawn` (not `spawn_link`) keeps the owner's death out of the test process.
  defp start_owned_delivery(build_fun) do
    parent = self()

    owner =
      spawn(fn ->
        result = Delivery.stream(self(), build_fun, nil, %PlanResponse{}, [])
        send(parent, {:delivery, self(), result})

        receive do
          :stop_owner -> :ok
        end
      end)

    assert_receive {:delivery, ^owner, result}, 2_000
    {owner, result}
  end

  describe "explicit cancel" do
    test "finalizes the suspended stream and stops the session" do
      assert {:ok, prepared} =
               Delivery.stream(self(), build_fun(cleanup_stream()), nil, %PlanResponse{}, [])

      assert prepared.first_chunk == "first chunk"
      assert :ok = prepared.cancel.()
      assert_receive {:stream_finalized, :second}
    end

    test "is idempotent — a second cancel after the session is gone still returns" do
      assert {:ok, prepared} =
               Delivery.stream(self(), build_fun(cleanup_stream()), nil, %PlanResponse{}, [])

      assert :ok = prepared.cancel.()
      assert_receive {:stream_finalized, :second}

      await_session_gone()
      assert {:error, {:session, :noproc}} = prepared.cancel.()
    end
  end

  describe "stream completion" do
    test "next yields each chunk then done, and the session is gone afterwards" do
      assert {:ok, prepared} =
               Delivery.stream(
                 self(),
                 build_fun(["first chunk", "second chunk"]),
                 nil,
                 %PlanResponse{},
                 []
               )

      assert prepared.first_chunk == "first chunk"
      assert {:chunk, "second chunk"} = prepared.next.()
      assert :done = prepared.next.()

      await_session_gone()
      assert {:error, {:session, :noproc}} = prepared.next.()
    end
  end

  describe "prepare failure" do
    test "a build_fun that fails before pump returns its tagged error" do
      build_fun = fn _pump -> {:error, {:decode, :not_an_image}} end

      assert {:error, {:decode, :not_an_image}} =
               Delivery.stream(self(), build_fun, nil, %PlanResponse{}, [])
    end

    test "an empty encoder stream is a pre-response encode error" do
      assert {:error, {:encode, :empty_stream}} =
               Delivery.stream(self(), build_fun([]), nil, %PlanResponse{}, [])
    end

    test "a caller-supplied timeout on a wedged prepare is a tagged session timeout" do
      test_pid = self()

      build_fun = fn _pump ->
        send(test_pid, {:build_started, self()})

        receive do
          :release -> {:error, {:source, :released}}
        end
      end

      {:ok, coordinator} = Coordinator.start(build_fun, self(), nil, nil, [])

      assert {:error, {:session, :timeout}} = Coordinator.prepare(coordinator, 100)
      assert_receive {:build_started, producer}
      send(producer, :release)
    end
  end

  describe "owner death" do
    test "cleans up the session once the owner exits" do
      {owner, {:ok, _prepared}} = start_owned_delivery(build_fun(cleanup_stream()))
      owner_ref = Process.monitor(owner)

      send(owner, :stop_owner)

      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
      assert_receive {:stream_finalized, :second}
    end

    test "replies to an in-flight next and stops a wedged producer via the halt backstop" do
      {owner, {:ok, prepared}} = start_owned_delivery(build_fun(gated_second_chunk_stream()))
      owner_ref = Process.monitor(owner)
      parent = self()

      caller = spawn(fn -> send(parent, {:next_result, prepared.next.()}) end)
      caller_ref = Process.monitor(caller)

      assert_receive {:before_second_chunk, producer}
      producer_ref = Process.monitor(producer)

      send(owner, :stop_owner)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

      assert_receive {:next_result, {:error, {:session, {:owner_down, :normal}}}}, 2_000
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
      assert_receive {:DOWN, ^producer_ref, :process, ^producer, _reason}, 2_000
    end
  end

  describe "cancel during a pending next" do
    test "replies to the pending caller before stopping" do
      assert {:ok, prepared} =
               Delivery.stream(
                 self(),
                 build_fun(gated_second_chunk_stream()),
                 nil,
                 %PlanResponse{},
                 []
               )

      parent = self()
      caller = spawn(fn -> send(parent, {:next_result, prepared.next.()}) end)
      caller_ref = Process.monitor(caller)

      assert_receive {:before_second_chunk, producer}
      producer_ref = Process.monitor(producer)

      assert :ok = prepared.cancel.()
      assert_receive {:next_result, {:error, {:session, :cancelled}}}
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
      assert_receive {:DOWN, ^producer_ref, :process, ^producer, _reason}, 2_000
    end
  end

  # Required by the D3 ruling. Baseline A pins that the producer TERMINATES and
  # the cache sink aborts on owner death — but neither implies the producer's
  # bracket `after` ran. A coordinator whose graceful halt regressed to a
  # force-kill would keep Baseline A green while silently skipping the bracket,
  # which is the entire reason `request_producer_halt/3` exists. So assert the
  # bracket ran, and that it ran exactly once.
  describe "bracket cleanup on graceful owner-down" do
    test "runs the producer's bracket cleanup exactly once" do
      {owner, {:ok, _prepared}} = start_owned_delivery(bracketed_build_fun(cleanup_stream()))
      owner_ref = Process.monitor(owner)

      refute_received :bracket_cleanup

      send(owner, :stop_owner)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

      assert_receive :bracket_cleanup, 2_000
      refute_receive :bracket_cleanup, 300
    end

    test "runs the producer's bracket cleanup exactly once on explicit cancel" do
      assert {:ok, prepared} =
               Delivery.stream(
                 self(),
                 bracketed_build_fun(cleanup_stream()),
                 nil,
                 %PlanResponse{},
                 []
               )

      refute_received :bracket_cleanup

      assert :ok = prepared.cancel.()

      assert_receive :bracket_cleanup, 2_000
      refute_receive :bracket_cleanup, 300
    end

    test "runs the producer's bracket cleanup exactly once on normal completion" do
      assert {:ok, prepared} =
               Delivery.stream(
                 self(),
                 bracketed_build_fun(["first chunk", "second chunk"]),
                 nil,
                 %PlanResponse{},
                 []
               )

      assert {:chunk, "second chunk"} = prepared.next.()
      assert :done = prepared.next.()

      assert_receive :bracket_cleanup, 2_000
      refute_receive :bracket_cleanup, 300
    end
  end
end

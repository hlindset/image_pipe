defmodule ImagePipe.Request.DeliveryOwnerCleanupBaselineTest do
  @moduledoc """
  D3 topology-gate BASELINE A (immutable): topology-neutral owner-death
  cleanup, observed entirely through the public Plug surface (no
  `ImagePipe.Request.SourceSession*` module is named anywhere in this file).
  Task 3 must keep this test passing UNMODIFIED after the D3 migration; a
  weakened or edited assertion is a gate failure.

  The delivery-owning process — the one that called `ImagePipe.Plug.call/2` —
  is killed mid-stream, after the first chunk of a multi-chunk response but
  before the second. This characterizes the ONLY termination path the future
  monitor topology will have (there is no supervisor to fall back on), so it
  is exactly the guarantee that must survive D3 identically.

  Observation-point note: a raw process kill does NOT gracefully halt the
  encoder's output stream — `Stream.resource/3`'s `after` callback only runs
  when the reduce is explicitly told to halt, never on the owning process
  dying (verified empirically: a `Stream.resource`-based `image_module` stub's
  `after` callback never fires on owner kill, in either the encode-stream or
  a hand-rolled `Stream.resource` case). So this test does not observe cleanup
  via a stream-finalize hook — no such hook reliably fires here. Instead it
  observes the real `[:cache, :stage]` telemetry event that
  `ImagePipe.Request.SourceSession` emits when it aborts the open cache sink
  on owner death (`cache: :stage_abandoned, reason: :owner_down`) — genuine
  production instrumentation (a documented `:telemetry` event, part of the
  `ImagePipe.Cache` adapter contract), not a supervisor-internal count. This
  satisfies the required semantics (an in-flight signal to time the kill, and
  an exactly-once cleanup signal) with a signal that is actually guaranteed to
  fire, rather than one whose skeleton merely looked plausible.
  """

  use ExUnit.Case, async: false

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.OriginImage

  # Stand-in `image_module` producing a two-chunk output stream, where the
  # second chunk blocks until released — giving the test a reliable
  # "mid-delivery" window between the first chunk (already sent to the conn)
  # and the second (not yet produced). Shaped exactly like the real
  # `image_module.stream!/2` contract (`ImagePipe.Output.Encoder` calls it the
  # same way it would call the real `Image.stream!/2`), so this is a
  # substitution at a real extension point, not a peek into internals.
  defmodule GatedTwoChunkImage do
    @event_target ImagePipe.Request.DeliveryOwnerCleanupBaselineTest.StreamEvents

    def stream!(_image, _opts) do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :second}

          :second ->
            if target = Process.whereis(@event_target) do
              send(target, {:delivery_in_flight, self()})
            end

            receive do
              :release -> {["second chunk"], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn _state -> :ok end
      )
    end
  end

  test "owner death mid-stream cleans up exactly once (public-surface observation)" do
    register_stream_events!()

    telemetry_prefix = [:"d3_baseline_a_#{System.unique_integer([:positive])}"]
    stage_event = telemetry_prefix ++ [:cache, :stage]
    test_pid = self()
    handler_id = "d3-baseline-a-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      stage_event,
      fn _event, _measurements, meta, _config -> send(test_pid, {:cache_stage, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ],
      image_module: GatedTwoChunkImage,
      cache: {CacheProbe, [result: :miss]},
      telemetry_prefix: telemetry_prefix
    ]

    owner =
      spawn(fn ->
        conn = Plug.Test.conn(:get, "/unsafe/rs:fit:64:64/plain/images/cat.jpg")
        ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
      end)

    owner_ref = Process.monitor(owner)

    # In-flight signal: first chunk already delivered to the conn, second
    # chunk pending — this is our window to kill the owner mid-stream.
    assert_receive {:delivery_in_flight, _producer}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 2_000

    # cleanup exactly once: the cache-sink abort telemetry fires exactly one time
    assert_receive {:cache_stage, %{cache: :stage_abandoned, reason: :owner_down}}, 2_000
    refute_receive {:cache_stage, _}, 100
  end

  defp register_stream_events! do
    Process.register(self(), __MODULE__.StreamEvents)
  end
end

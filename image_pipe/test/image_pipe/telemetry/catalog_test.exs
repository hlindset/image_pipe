defmodule ImagePipe.Telemetry.CatalogTest do
  # Attaches the default Logger and the tracer, whose handler IDs are global.
  use ExUnit.Case, async: false

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Catalog

  setup do
    on_exit(fn ->
      Telemetry.detach_default_logger()
      Telemetry.detach_tracer()
    end)
  end

  test "the event reference documents every event" do
    reference = File.read!("docs/telemetry-events.md")

    undocumented =
      for {stage, _kind, _group, _logged?} <- Catalog.entries(),
          not String.contains?(reference, "`#{inspect(stage)}`"),
          do: stage

    assert undocumented == []
  end

  test "the Logger and the tracer subscribe to every event, except trace-only ones in the Logger" do
    prefix = [__MODULE__, :subscriptions]
    Telemetry.attach_default_logger(prefix: prefix)
    Telemetry.attach_tracer(prefix: prefix, finch_spans: false)

    logged = subscribed(prefix, "image-pipe-default-logger")
    traced = subscribed(prefix, {Telemetry.Trace.Handler, :spans})

    for {stage, kind, _group, logged?} <- Catalog.entries() do
      {stop, start} =
        case kind do
          :span -> {prefix ++ stage ++ [:stop], prefix ++ stage ++ [:start]}
          :oneshot -> {prefix ++ stage, prefix ++ stage}
        end

      assert {stage, MapSet.member?(traced, stop)} == {stage, true}
      assert {stage, MapSet.member?(traced, start)} == {stage, true}
      assert {stage, MapSet.member?(logged, stop)} == {stage, logged?}
    end
  end

  test "the Logger subscribes only to the selected groups" do
    prefix = [__MODULE__, :groups]
    Telemetry.attach_default_logger(prefix: prefix, events: [:output])

    logged = subscribed(prefix, "image-pipe-default-logger")

    assert MapSet.member?(logged, prefix ++ [:output, :clamp])
    assert MapSet.member?(logged, prefix ++ [:output, :negotiate, :stop])
    refute MapSet.member?(logged, prefix ++ [:request, :stop])
    refute MapSet.member?(logged, prefix ++ [:cache, :coordination])
  end

  defp subscribed(prefix, handler_id) do
    for %{id: ^handler_id, event_name: event} <- :telemetry.list_handlers(prefix),
        into: MapSet.new(),
        do: event
  end
end

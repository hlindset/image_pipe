defmodule ImagePipe.Test.Telemetry do
  @moduledoc """
  Test-only telemetry capture that is safe under `async: true`.

  `:telemetry` handlers run synchronously in the process that *emits* the event,
  but the handler table is global to the VM. `:telemetry_test.attach_event_handlers/2`
  therefore fires for events emitted by *any* process — including concurrent async
  test modules — and stamps each one with the attaching test's `ref` before
  delivering it to the attaching test's mailbox. That contaminates
  `assert_receive`/`refute_received`: a foreign module emitting the same event
  (e.g. another module exercising `[:transform, :detect, :stop]` or
  `[:image_pipe, :deliver, :stop]`) lands a `^ref`-matching message in this test's
  mailbox even though this test never triggered it.

  `attach_own_event_handlers/2` closes that hole by forwarding only events emitted
  by the *attaching* process. Because handlers run in the emitter, `self() == owner`
  inside the handler is true exactly when this test triggered the event and false
  for every concurrent module. The message shape and the `ref`-as-handler-id
  contract match `:telemetry_test.attach_event_handlers/2`, so `:telemetry.detach(ref)`
  still works.

  This is sound only for events the test triggers synchronously in its own process,
  which is the case for the transform and response-sender tests that use it.
  """

  @spec attach_own_event_handlers(pid(), [[atom()]]) :: reference()
  def attach_own_event_handlers(owner, events) when is_pid(owner) and is_list(events) do
    ref = make_ref()

    :ok =
      :telemetry.attach_many(
        ref,
        events,
        &__MODULE__.handle_event/4,
        %{owner: owner, ref: ref}
      )

    ref
  end

  @doc false
  def handle_event(event, measurements, metadata, %{owner: owner, ref: ref}) do
    if self() == owner do
      send(owner, {event, ref, measurements, metadata})
    end

    :ok
  end
end

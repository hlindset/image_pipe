defmodule ImagePipe.Test.DecodeOpens do
  @moduledoc false
  # Forwards each libvips open of an original, the `[:source, :decode_open]`
  # span's start, to the test process as `{:loader_open, metadata}` for the
  # test's own telemetry prefix.

  def forward(prefix) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        prefix ++ [:source, :decode_open, :start],
        fn _event, _measurements, metadata, pid -> send(pid, {:loader_open, metadata}) end,
        self()
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
  end
end

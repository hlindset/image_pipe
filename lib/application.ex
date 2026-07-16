defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ]

  use Application

  require Logger

  alias ImagePipe.Output.Capabilities

  @impl true
  def start(_type, _args) do
    Capabilities.probe()

    children = [
      ImagePipe.Telemetry.Trace.OtelReplay,
      ImagePipe.Source.S3.RefreshCache
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end

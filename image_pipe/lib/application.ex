defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
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
      {Task.Supervisor, name: ImagePipe.ProcessingPool.Tasks},
      {DynamicSupervisor, name: ImagePipe.Source.Downloads, strategy: :one_for_one},
      ImagePipe.Cache.Resources,
      {Task.Supervisor, name: ImagePipe.Cache.RefreshTasks},
      ImagePipe.Cache.Work,
      ImagePipe.Cache.OutputWork,
      ImagePipe.Telemetry.Trace.OtelReplay,
      ImagePipe.Source.S3.RefreshCache
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end

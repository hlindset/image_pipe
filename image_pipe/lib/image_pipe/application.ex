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

  alias ImagePipe.Output.Capabilities

  @impl true
  def start(_type, _args) do
    Capabilities.probe()

    children = [
      {Task.Supervisor, name: ImagePipe.ProcessingPool.Tasks},
      {DynamicSupervisor, name: ImagePipe.Source.Downloads, strategy: :one_for_one},
      {DynamicSupervisor, name: ImagePipe.Source.HTTP.Pools, strategy: :one_for_one},
      ImagePipe.Source.HTTP.PinnedPools,
      ImagePipe.Cache.Resources,
      {Task.Supervisor, name: ImagePipe.Cache.RefreshTasks},
      ImagePipe.Cache.Work,
      ImagePipe.Cache.OutputWork,
      ImagePipe.Telemetry.Trace.OtelReplay,
      ImagePipe.Source.S3.RefreshCache,
      {Task, &ImagePipe.Cache.sweep_staged/0}
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Supervisor.start_link(children, opts)
  end
end

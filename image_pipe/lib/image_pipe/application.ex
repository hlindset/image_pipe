defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Output,
      ImagePipe.Source
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
      ImagePipe.Cache.FileSystem.CheckedDirs,
      {Task.Supervisor, name: ImagePipe.Cache.RefreshTasks},
      ImagePipe.Cache.Work,
      ImagePipe.Cache.OutputWork,
      ImagePipe.Source.S3.RefreshCache,
      ImagePipe.Cache.staged_sweep_spec()
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Supervisor.start_link(children, opts)
  end
end

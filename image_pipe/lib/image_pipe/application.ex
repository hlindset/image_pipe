defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Execution,
      ImagePipe.Output,
      ImagePipe.Source,
      ImagePipe.SrgbProfile
    ]

  use Application

  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Execution.Staging
  alias ImagePipe.Output.Capabilities

  @impl true
  def start(_type, _args) do
    Capabilities.probe()

    children = [
      ImagePipe.SrgbProfile,
      {Task.Supervisor, name: ImagePipe.ProcessingPool.Tasks},
      {DynamicSupervisor, name: ImagePipe.Source.Downloads, strategy: :one_for_one},
      {DynamicSupervisor, name: ImagePipe.Source.HTTP.Pools, strategy: :one_for_one},
      ImagePipe.Source.HTTP.PinnedPools,
      ImagePipe.Source.HTTP.DnsCache,
      Staging.Resources,
      ImagePipe.Cache.FileSystem.CheckedDirs,
      ImagePipe.Cache.FileSystem.RefusedRoots,
      {Task.Supervisor, name: ImagePipe.Cache.RefreshTasks},
      ImagePipe.Cache.Work,
      OutputWork,
      ImagePipe.Source.S3.RefreshCache,
      Staging.sweep_spec()
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Supervisor.start_link(children, opts)
  end
end

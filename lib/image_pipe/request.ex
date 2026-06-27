defmodule ImagePipe.Request do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.MaterialDigest,
      ImagePipe.Plan,
      ImagePipe.Cache,
      ImagePipe.Source,
      ImagePipe.Output,
      ImagePipe.Response,
      ImagePipe.Renderer,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [
      HTTPCache,
      Options,
      Runner,
      SourceSessionSupervisor
    ]
end

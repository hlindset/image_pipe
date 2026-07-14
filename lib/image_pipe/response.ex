defmodule ImagePipe.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ],
    exports: [
      CacheHeaders,
      Conditional,
      CORS,
      ErrorStatus,
      Json,
      PreparedStream,
      Sender
    ]
end

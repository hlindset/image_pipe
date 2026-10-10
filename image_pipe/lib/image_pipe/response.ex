defmodule ImagePipe.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Delivery,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Telemetry
    ],
    exports: [
      CacheHeaders,
      CachePolicy,
      Conditional,
      CORS,
      ErrorStatus,
      Sender
    ]
end

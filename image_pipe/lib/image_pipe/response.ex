defmodule ImagePipe.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Delivery,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Telemetry
    ],
    exports: [
      CacheHeaders,
      CachePolicy,
      Conditional,
      Discard,
      CORS,
      ErrorStatus,
      Sender
    ]
end

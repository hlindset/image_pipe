defmodule ImagePipe.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ],
    exports: [
      Capabilities,
      Clamp,
      Encoder,
      Negotiate,
      Negotiation,
      Policy,
      Resolved,
      Terminal.Blurhash
    ]
end

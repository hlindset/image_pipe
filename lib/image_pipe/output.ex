defmodule ImagePipe.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ],
    exports: [
      Capabilities,
      Clamp,
      Encoder,
      Negotiation,
      Policy,
      Resolved,
      Terminal.Blurhash,
      Terminal.LqipCss
    ]
end

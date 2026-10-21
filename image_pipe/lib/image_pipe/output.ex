defmodule ImagePipe.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.SrgbProfile,
      ImagePipe.Telemetry
    ],
    exports: [
      Capabilities,
      Encoder,
      Negotiation,
      Policy,
      Resolved,
      Skipped,
      Terminal.Blurhash,
      Terminal.LqipCss
    ]
end

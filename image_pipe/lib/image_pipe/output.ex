defmodule ImagePipe.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.BitDepth,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.SrgbProfile,
      ImagePipe.Telemetry,
      ImagePipe.VipsHeader
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

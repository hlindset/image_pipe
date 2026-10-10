defmodule ImagePipe.API do
  # ImagePipe's URL grammar: lexing, parsing, presets, canonical serialization,
  # and URL generation. `ImagePipe.URL` builds URLs and `ImagePipe.Plug`
  # verifies, parses, and serves requests through this module set.
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Security],
    exports: [Diagnostic, Parser, Path, Presets, URL]
end

defmodule ImagePipe.Debug do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan],
    exports: [
      Headers,
      Info,
      Timing
    ]
end

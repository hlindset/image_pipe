defmodule ImagePipe.Test.ForwardRouter do
  @moduledoc false
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/images",
    to: ImagePipe.Plug,
    init_opts: [
      sources: [
        path:
          {ImagePipe.Source.File, root: Path.expand("sources", __DIR__), root_id: "forward-test"}
      ]
    ]
end

defmodule ImagePipe.Plug do
  @moduledoc """
  Mounts ImagePipe's image API.

      plug ImagePipe.Plug, sources: [...]

  Reuse host configuration with the Elixir API:

      config = ImagePipe.config(sources: [...], quality: 82)
      client = ImagePipe.new(config)
      mount = ImagePipe.Plug.init(config: config, http_cache: [mode: :enabled])

  ImagePipe URLs use options such as `/w=300/format=webp/src/images/photo.jpg`.
  Options within a group have a fixed processing order; `-` starts the
  next group. Configuration is validated at initialization, and invalid
  requests are rejected before source fetching or cache access.
  """

  use Boundary,
    deps: [
      ImagePipe.API,
      ImagePipe.Config,
      ImagePipe.Error,
      ImagePipe.Execution,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Plug.Config
  alias ImagePipe.Plug.Runner

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    Runner.run(conn, opts)
  end
end

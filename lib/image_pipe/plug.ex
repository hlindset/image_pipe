defmodule ImagePipe.Plug do
  @moduledoc """
  Mounts ImagePipe's image API.

      plug ImagePipe.Plug, sources: [...]

  ImagePipe URLs use options such as `/w=300/format=webp/src/images/photo.jpg`.
  Options within a group have a fixed processing order; `then` starts the
  next group. Configuration is validated at initialization, and invalid
  requests are rejected before source fetching or cache access.
  """

  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.API,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.API
  alias ImagePipe.Plug.Runner

  @impl Plug
  def init(opts), do: API.validate_config!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    Runner.run(conn, opts)
  end
end

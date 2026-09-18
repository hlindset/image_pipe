defmodule ImagePipe.Plug do
  @moduledoc """
  Mounts ImagePipe's native image API.

      plug ImagePipe.Plug, sources: [...]

  Native URLs use options such as `/w=300/format=webp/src/images/photo.jpg`.
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
      ImagePipe.Dialect,
      ImagePipe.Native,
      ImagePipe.Error,
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

  alias ImagePipe.Plug.DialectRunner

  @impl Plug
  def init(opts) do
    dialect = Keyword.get(opts, :dialect, ImagePipe.Native)

    unless is_atom(dialect) do
      raise ArgumentError, "dialect: expected a module, got: #{inspect(dialect)}"
    end

    [dialect: dialect] ++ dialect.validate_config!(Keyword.delete(opts, :dialect))
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    DialectRunner.run(conn, Keyword.fetch!(opts, :dialect), opts)
  end
end

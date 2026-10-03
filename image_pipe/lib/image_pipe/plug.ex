defmodule ImagePipe.Plug do
  @moduledoc """
  Mounts ImagePipe's image API.

      plug ImagePipe.Plug, sources: [...]

  Share URL settings with a builder and host configuration with direct execution:

      url_config = ImagePipe.URL.config(keys: [signing_key])
      config = ImagePipe.config(url: url_config, presets: presets, sources: [...], quality: 82)
      mount = ImagePipe.Plug.init(config: config, http_cache: :auto)

      url =
        ImagePipe.URL.new(ImagePipe.url_config(config))
        |> ImagePipe.URL.url!("images/cat.jpg")

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
      ImagePipe.Presets,
      ImagePipe.Processing,
      ImagePipe.Response,
      ImagePipe.Security,
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
  def call(%Plug.Conn{} = conn, {:instance, _name, _url, _mount} = mount) do
    Runner.run(conn, Config.resolve(mount))
  end

  def call(%Plug.Conn{} = conn, opts) do
    Runner.run(conn, opts)
  end
end

defmodule ImagePipe.Plug do
  @moduledoc """
  Serves ImagePipe's image API from a Plug or Phoenix router. Each place it is
  plugged in is a mount, with its own options.

      forward "/images", ImagePipe.Plug, sources: [...]

  In a `Plug.Router`, pass the options as `:init_opts`:

      forward "/images", to: ImagePipe.Plug, init_opts: [sources: [...]]

  A mount answers `GET`, `HEAD`, and `OPTIONS`. Other methods get `405`.
  [Getting started with Phoenix](phoenix-getting-started.md) walks through
  setting up a mount.

  An inline mount accepts every option of `ImagePipe.config/1`, or a
  `:config` built with it, plus the mount options below. It can't start the
  processes that a cache and the remembered originals need, so `init/1`
  raises `ArgumentError` for a configuration with `:cache` or
  `:max_remembered_originals`. To use a cache, read runtime values, or share
  the configuration with `ImagePipe.run/4`, mount an instance instead.

  The URLs a mount serves are described in
  [Requesting images](requesting-images.md). A mount checks their signatures
  with the configuration's `:keys`. Without `:keys`, it raises `ArgumentError`
  on every request unless the configuration sets `allow_unsigned: true`. See
  [Signing URLs](signing-urls.md).

  ## Mounting an instance

  Phoenix evaluates `forward` options at compile time. When the configuration
  reads runtime values, such as keys from environment variables, or uses a
  cache, run it as an instance (see `ImagePipe.child_spec/1`) and
  mount the instance by name:

      forward "/images", ImagePipe.Plug, instance: MyApp.Images, http_cache: :auto

  The configuration belongs to the instance, so with `:instance` a mount
  accepts only the mount options below. Other options raise `ArgumentError`.
  A request to a mount whose instance isn't running raises `ArgumentError`.

  #{NimbleOptions.docs(ImagePipe.Plug.Config.instance_schema())}

  ## Mount options

  These apply to one mount, inline or on an instance.

  #{NimbleOptions.docs(ImagePipe.Plug.Config.options_schema())}

  `init/1` validates the options. An instance mount looks up its instance per
  request.
  """

  use Boundary,
    deps: [
      ImagePipe.API,
      ImagePipe.Config,
      ImagePipe.Execution,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Presets,
      ImagePipe.Processing,
      ImagePipe.ProcessingPool,
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
  def call(%Plug.Conn{} = conn, opts), do: Runner.run(conn, Config.resolve(opts))
end

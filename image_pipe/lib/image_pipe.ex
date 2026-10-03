defmodule ImagePipe do
  @moduledoc """
  Executes processing plans and holds the host configuration shared with `ImagePipe.Plug`.

  Build plans and URLs with `ImagePipe.URL`. Execute a plan in-process with
  `run/4` or `write/5`, using a server configuration from `config/1`:

      url_config = ImagePipe.URL.config(keys: [signing_key])
      config = ImagePipe.config(url: url_config, presets: presets, sources: [...], quality: 82)

      builder =
        ImagePipe.URL.new(ImagePipe.url_config(config))
        |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
        |> ImagePipe.URL.output(format: :webp)

      {:ok, result} = ImagePipe.run(config, builder, {:source, "images/cat.jpg"})

  An instance is a supervised process that holds a configuration and starts
  the processes its caches need. Run one with `child_spec/1` when a mount's
  configuration reads runtime values, such as environment variables, or when
  the configuration uses a bounded cache. `ImagePipe.Plug` mounts and
  `config!/1` find it by name.
  """

  use Boundary,
    deps: [
      ImagePipe.API,
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Error,
      ImagePipe.Execution,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Presets,
      ImagePipe.Processing,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Security,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform,
      ImagePipe.URL
    ],
    exports: [Plug, Result]

  alias ImagePipe.Config

  @doc """
  Builds reusable, redacted host configuration for direct execution and Plug.

  Owns sources, caches, processing defaults, limits, storage partitions, and
  presets. `:url` takes an `ImagePipe.URL.Config` from `ImagePipe.URL.config/1`
  with the signing keys and source encryption the mount verifies; it defaults to
  an unsigned configuration.

  `:presets` maps names to option fragments or `ImagePipe.URL` builders.
  Nested references resolve at configuration time. `:request_defaults` is one
  single-group fragment or builder applied to every request before selected
  presets and explicit options; it cannot reference presets. `:preset_lookup`
  is an optional `{module, options}` implementing `ImagePipe.PresetLookup`
  that resolves names `:presets` does not define, per request.
  `:max_preset_lookups` (default `32`, only with a lookup) caps the distinct
  names one request may look up.

  Invalid configuration raises `ArgumentError` without including credentials
  in the message.
  """
  @spec config(keyword()) :: Config.t()
  def config(options \\ []), do: Config.new!(options)

  @doc """
  Returns a child specification that runs a named ImagePipe instance.

  Start the instance in your application's supervision tree, before the
  endpoint that mounts it. Its options are evaluated when the application
  starts, so they can read environment variables:

      children = [
        {ImagePipe,
         name: MyApp.Images,
         sources: [...],
         cache:
           {ImagePipe.Cache.FileSystem,
            root: "/var/cache/image_pipe/processed",
            max_size_bytes: 5_000_000_000,
            node_id: "node-0"}},
        MyAppWeb.Endpoint
      ]

  Mount it with the `:instance` option of `ImagePipe.Plug`, and get its
  configuration for `run/4` with `config!/1`.

  A bounded `ImagePipe.Cache.FileSystem` runs processes that track the
  cache's size, and only an instance starts them. A configuration with such a
  cache must be used through an instance. An inline `ImagePipe.Plug` mount,
  and `run/4` with a configuration from `config/1`, raise `ArgumentError` for
  it. Setting one up is covered in
  [Caching processed images](caching-processed-images.md).

  ## Options

  #{NimbleOptions.docs(ImagePipe.Instance.options_schema())}

  Every option of `config/1` is accepted too. Invalid options raise
  `ArgumentError` when the child specification is built, before the
  instance starts.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options), do: ImagePipe.Instance.child_spec(options)

  @doc """
  Returns the configuration of a running instance, for `run/4` and `write/5`.

      config = ImagePipe.config!(MyApp.Images)
      {:ok, result} = ImagePipe.run(config, builder, {:source, "images/cat.jpg"})

  The configuration uses the instance's `:url`. The named `:urls` are
  available only to mounts, so `url_config/1` returns the default URL
  settings.
  Raises `ArgumentError` if no instance with that name is running.
  """
  @spec config!(atom()) :: Config.t()
  def config!(name), do: Config.fetch_instance!(name, nil)

  @doc """
  Returns the configuration's URL settings for building URLs it will serve.

  The result carries this configuration's presets and request defaults as
  `:mount_presets`, so `ImagePipe.URL.validate/1` and `ImagePipe.URL.url/3`
  check plans against them.
  """
  @spec url_config(Config.t()) :: ImagePipe.URL.Config.t()
  def url_config(%Config{url: url}), do: url

  @doc """
  Checks a builder's plan as this configuration would serve it.

  Applies request defaults and presets, including the preset lookup, then
  checks the request and its output policy. Returns `:ok` or the error
  `run/4` would return, without reading a source or accessing a cache.
  """
  @spec validate(Config.t(), ImagePipe.URL.t()) :: :ok | {:error, term()}
  def validate(config, builder), do: ImagePipe.Run.validate(config, builder)

  @doc """
  Executes a builder's plan and returns a fully consumed `ImagePipe.Result`.

  Inputs are `{:file, path}`, `{:binary, bytes}`, or `{:source, source_string}`.
  Configured sources use the config's sources, input/output caches, processing
  defaults, detector, limits, and telemetry. Presets and request defaults
  resolve from the config, as on the mount; the builder's own URL configuration
  is used only for URL generation. Per-call host options override the reusable
  configuration. File and binary inputs bypass both caches.
  `accept: "image/webp"` supplies optional format negotiation preferences.

  `request_inputs: [headers: [{"x-tenant", "one"}], cookies: %{"session" => "abc"}]`
  supplies values named by `storage_inputs`, matching HTTP cache partitions.
  These values affect storage identity; source adapters use their own settings.

  Returns `{:ok, result}` or a tagged runtime error. Invalid configuration
  raises `ArgumentError`. All lazy pixel and encoding work finishes before
  source resources are closed.
  """
  @spec run(Config.t(), ImagePipe.URL.t(), {:file | :binary | :source, binary()}, keyword()) ::
          {:ok, ImagePipe.Result.t()} | {:error, term()}
  def run(config, builder, input, options \\ []),
    do: ImagePipe.Run.run(config, builder, input, options)

  @doc """
  Runs a plan, then writes the complete result to a file.

  Returns the same result as `run/4`. Info results are serialized as JSON.
  An existing file is overwritten. Write failures return
  `{:error, {:destination, reason}}` after all source resources are released.
  """
  @spec write(
          Config.t(),
          ImagePipe.URL.t(),
          {:file | :binary | :source, binary()},
          Path.t(),
          keyword()
        ) :: {:ok, ImagePipe.Result.t()} | {:error, term()}
  def write(config, builder, input, path, options \\ []),
    do: ImagePipe.Run.write(config, builder, input, path, options)
end

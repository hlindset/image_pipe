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

  @doc false
  def child_spec(options), do: ImagePipe.Instance.child_spec(options)

  @doc false
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

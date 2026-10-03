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
  Runs a builder's plan on an image and returns the encoded result.

      builder =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(resize: [width: 400])
        |> ImagePipe.URL.output(format: :webp)

      {:ok, result} = ImagePipe.run(ImagePipe.config(), builder, {:file, "photos/cat.jpg"})
      result.content_type
      #=> "image/webp"

  `config` comes from `config/1`, or from `config!/1` when the configuration
  has a bounded cache. Presets and request defaults come from `config`, as
  for a request to an `ImagePipe.Plug` mount. The builder's own URL
  configuration isn't used. Matching source bytes, plans, settings, and
  `Accept` preferences give the same result as an HTTP request.

  ## Inputs

    * `{:source, source}` - a source the configuration's
      [source mounts](sources.md#routing-image-paths-to-sources) resolve, as for an HTTP
      request: a path, an HTTP(S) URL such as
      `"https://assets.example.com/cat.jpg"`, an S3 identifier, or a custom
      scheme. Pass the source without the `src/` marker or the URL escaping
      of the request path. The mount's network, redirect, timeout, and
      content-type policies apply. These inputs use the configuration's
      caches, so `run/4` and HTTP requests reuse each other's stored copies
      when the plan, `Accept` preferences, and request inputs match.
    * `{:file, path}` - a local file, by absolute path or relative to the
      current working directory. Symlinks are followed, and the path must
      end at a regular file. The path isn't confined to a directory. Use a
      `{:source, path}` with an `ImagePipe.Source.File` mount for that.
    * `{:binary, bytes}` - an encoded image in memory, such as an upload.

  `{:file, path}` and `{:binary, bytes}` inputs are never cached. Every input
  is subject to `:max_body_bytes`, `:max_input_pixels`, and
  `:max_input_frames`.

  ## Options

  Options of `config/1` override the configuration for this call, such as
  `max_input_pixels: 50_000_000`. Invalid options raise `ArgumentError`.
  A configuration from `config!/1` takes the same options, but a bounded
  `:cache` or `:input_cache` raises `ArgumentError` unless it is one of the
  instance's own caches.

    * `:accept` (`t:String.t/0`) - an HTTP `Accept` value, such as
      `"image/avif,image/webp"`, for choosing the output format when the plan
      has no `format`. The default `""` keeps the original's format where
      possible, as for a request without `Accept` (see
      [output formats](requesting-images.md#output-formats)). `:auto_avif`,
      `:auto_webp`, `:format_order`, and `:output_capabilities` apply as on
      a mount.
    * `:request_inputs` (`t:keyword/0`) - the header and cookie values named
      by the configuration's `:storage_inputs`, as
      `[headers: [{"x-tenant", "one"}], cookies: %{"session" => "abc"}]`.
      They select a stored copy as the same values in an HTTP request would.
      Header names are case-insensitive, and cookie names are
      case-sensitive. A missing value matches a request without it. They
      aren't sent to the source and don't change the result.

  The builder's request controls behave as in a URL. `cachebuster` selects a
  separate stored copy. `expires` is compared with the configuration's
  `:clock`, and a plan is still valid at its exact `expires` second.
  `filename`, `attachment`, and `debug` don't change the result.

  ## Return values

  Returns `{:ok, %ImagePipe.Result{}}`, or `{:error, reason}`:

    * `{:invalid_request, issues}` - the builder's options don't combine, or
      it names an unknown preset or watermark. `issues` is a list of
      `ImagePipe.Plan.Spec.Issue`.
    * `:expired` - the plan's `expires` time has passed.
    * `{:invalid_output, reason}` - the output options can't be combined,
      such as `color_profile: {:convert, :srgb}` with `hdr: :preserve`. A
      configured default counts too.
    * `{:unsupported_output_format, format}` - no encoder for the format.
    * `{:detector, reason}` - detection is required and `reason` is
      `:unavailable` or `:not_ready`, or the plan names detection classes
      the detector lacks (`{:unknown_classes, names}`).
    * `{:preset, reason}` - the configuration's preset lookup failed:
      `:lookup_unavailable`, or `:invalid_definition`.
    * `{:invalid_source, reason}` - the input isn't one of the tuples above,
      the source isn't valid UTF-8, or the source or a `watermark_source` in
      the plan can't be parsed.
    * `{:source, reason}` - the source or a watermark source couldn't be
      read, such as `{:source, :enoent}` for a missing file,
      `{:source, :not_found}` for a source no mount matches, or
      `{:source, :body_too_large}`.
    * `{:input_limit, reason}` - the decoded image exceeds
      `:max_input_pixels` or `:max_input_frames`.
    * `{:page_out_of_range, page, pages}` - the builder's `page` doesn't
      exist in the original.
    * `{:decode, reason}` - the input isn't an image ImagePipe can decode.
    * `{:transform, reason}` - processing failed, such as a `region`
      outside the image.
    * `{:encode, reason}` or `{:encode, exception, stacktrace}` - encoding
      failed.
    * `{:processing, reason}` - the processing pool rejected or stopped the
      work, such as `:overloaded`, `:queue_timeout`, or `:timeout`.

  The checks that don't need the image run first, so `{:invalid_request, _}`,
  `:expired`, `{:invalid_output, _}`, `{:unsupported_output_format, _}`,
  `{:detector, _}`, and `{:preset, _}` return before any source is read. Errors raised by
  transform code propagate.

  ## Resources

  The result is complete when `run/4` returns, and holds no open file,
  source, or image. Source resources are closed before `run/4` returns, on
  success and on failure. The result is held in memory, so running large
  outputs concurrently needs memory for each complete result.
  """
  @spec run(Config.t(), ImagePipe.URL.t(), {:file | :binary | :source, binary()}, keyword()) ::
          {:ok, ImagePipe.Result.t()} | {:error, term()}
  def run(config, builder, input, options \\ []),
    do: ImagePipe.Run.run(config, builder, input, options)

  @doc """
  Runs a builder's plan like `run/4`, then writes the result to `path`.

      {:ok, result} =
        ImagePipe.write(ImagePipe.config(), builder, {:binary, upload}, "thumbs/cat.webp")

  Takes the same inputs and options, and returns the same result, as
  `run/4`. The file holds `result.data`, with an `:info` result written as
  JSON. An existing file is overwritten.

  The output format comes from the plan or from `:accept`, never from the
  file name, so `"cat.jpg"` can hold WebP. Set `format:` with
  `ImagePipe.URL.output/2` to match the file name.

  Returns `run/4`'s errors, or `{:error, {:destination, reason}}` when the
  file can't be written, such as `{:destination, :enoent}` for a missing
  directory. The file is written after source resources are closed.
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

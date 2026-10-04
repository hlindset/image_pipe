defmodule ImagePipe do
  @moduledoc """
  Processes images in your own code, and holds the configuration that
  `ImagePipe.Plug` serves images with.

      builder =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
        |> ImagePipe.URL.output(format: :webp)

      {:ok, result} = ImagePipe.run(ImagePipe.config(), builder, {:file, "cat.jpg"})

  `config/1` builds a configuration, `ImagePipe.URL` describes what to do to
  the image, and `run/4` returns the result. `write/5` writes it to a file
  instead. [Processing images in Elixir](processing-in-elixir.md) walks
  through it.

  An instance is a supervised process that holds a configuration and starts
  the processes its caches need. Run one with `child_spec/1` when a mount's
  configuration reads runtime values, such as environment variables, or when
  the configuration uses a bounded cache. `ImagePipe.Plug` mounts, `run/4`,
  `write/5`, `validate/2`, and `url_config/2` find it by name.
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

  @url_config_schema NimbleOptions.new!(
                       mount: [
                         type: :atom,
                         doc: """
                         One of the instance's `:mounts`, whose URL options the \
                         result uses instead of the instance's own.
                         """
                       ]
                     )

  @doc """
  Builds the configuration that `ImagePipe.Plug` mounts, instances, and
  `run/4` use.

      config =
        ImagePipe.config(
          sources: [
            media: [
              adapter: ImagePipe.Source.File,
              match: :path,
              options: [root: "/srv/images", root_id: "media"]
            ]
          ],
          presets: %{"card" => "w=400/h=300/fit=cover"},
          quality: 82
        )

  Invalid options raise `ArgumentError`, without credentials in the message.
  Building a configuration reads no sources or caches. Inspecting one hides its
  values.

  [Elixir configuration](configuration.md) shows which settings belong here and
  which belong to a mount, a source, or a request.

  `keys` and `source_encryption_keys` set which URLs an `ImagePipe.Plug`
  mount accepts. `base_url`, `encrypt_source`, and `iv_mode` only affect URLs
  built from the configuration with `url_config/2`.

  ## Options

  #{ImagePipe.Config.options_docs()}
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

  Mount it with the `:instance` option of `ImagePipe.Plug`, and pass its name
  to `run/4`, `write/5`, `validate/2`, and `url_config/2`.

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
  Returns the URL settings a configuration or a running instance serves, for
  building URLs with `ImagePipe.URL.new/1`.

      MyApp.Images
      |> ImagePipe.url_config()
      |> ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 400])
      |> ImagePipe.URL.url!("images/cat.jpg")

  The result carries the configuration's presets, request defaults, and
  watermark names as its `:validate_against` option, so
  `ImagePipe.URL.validate/1` and `ImagePipe.URL.url/3` check plans against
  them.

  ## Options

  #{NimbleOptions.docs(@url_config_schema)}

  Raises `ArgumentError` for an invalid option, when no instance with the
  name is running or it has no mount with that name, or when `:mount` comes
  with a configuration.
  """
  @spec url_config(Config.t() | atom(), keyword()) :: ImagePipe.URL.Config.t()
  def url_config(config_or_name, options \\ []) do
    case NimbleOptions.validate(options, @url_config_schema) do
      {:ok, options} -> fetch_url_config(config_or_name, options[:mount])
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  defp fetch_url_config(%Config{url: url}, nil), do: url

  defp fetch_url_config(%Config{}, _mount),
    do: raise(ArgumentError, "url_config/2 takes :mount only with an instance name")

  defp fetch_url_config(name, mount) when is_atom(name),
    do: Config.fetch_instance!(name, mount).url

  @doc """
  Checks a builder's plan as this configuration would serve it.

  Applies request defaults and presets, including the preset lookup, then
  checks the request and its output policy. Returns `:ok` or the error
  `run/4` would return, without reading a source or accessing a cache.
  """
  @spec validate(Config.t() | atom(), ImagePipe.URL.t()) :: :ok | {:error, term()}
  def validate(config, builder), do: ImagePipe.Run.validate(resolve(config), builder)

  @doc """
  Runs a builder's plan on an image and returns the encoded result.

      builder =
        ImagePipe.URL.new()
        |> ImagePipe.URL.group(resize: [width: 400])
        |> ImagePipe.URL.output(format: :webp)

      {:ok, result} = ImagePipe.run(ImagePipe.config(), builder, {:file, "photos/cat.jpg"})
      result.content_type
      #=> "image/webp"

  `config` comes from `config/1`, or is the name of a running instance. A
  configuration with a bounded cache must be passed by its instance's name.
  Presets and request defaults come from `config`, as for a request to an
  `ImagePipe.Plug` mount. The builder's own URL configuration isn't used.
  Matching source bytes, plans, settings, and `Accept` preferences give the
  same result as an HTTP request.

  ## Inputs

    * `{:source, source}` - a source the configuration's
      [configured sources](sources.md#routing-image-paths-to-sources) resolve, as for an HTTP
      request: a path, an HTTP(S) URL such as
      `"https://assets.example.com/cat.jpg"`, an S3 identifier, or a custom
      scheme. Pass the source without the `src/` marker or the URL escaping
      of the request path. The source's network, redirect, timeout, and
      content-type policies apply. These inputs use the configuration's
      caches, so `run/4` and HTTP requests reuse each other's stored copies
      when the plan, `Accept` preferences, and request inputs match.
    * `{:file, path}` - a local file, by absolute path or relative to the
      current working directory. Symlinks are followed, and the path must
      end at a regular file. The path isn't confined to a directory. Use a
      `{:source, path}` with an `ImagePipe.Source.File` source for that.
    * `{:binary, bytes}` - an encoded image in memory, such as an upload.

  `{:file, path}` and `{:binary, bytes}` inputs are never cached. Every input
  is subject to `:max_body_bytes`, `:max_input_pixels`, and
  `:max_input_frames`.

  ## Options

  Every option of `config/1` overrides the configuration for this call, such
  as `max_input_pixels: 50_000_000`. Invalid options raise `ArgumentError`.
  An instance name takes the same options, but a bounded `:cache` or
  `:input_cache` raises `ArgumentError` unless it is one of the instance's
  own caches. `run/4` and `write/5` also take:

  #{ImagePipe.Run.options_docs()}

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
      `{:source, :not_found}` for a path no configured source matches, or
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
  @spec run(
          Config.t() | atom(),
          ImagePipe.URL.t(),
          {:file | :binary | :source, binary()},
          keyword()
        ) :: {:ok, ImagePipe.Result.t()} | {:error, term()}
  def run(config, builder, input, options \\ []),
    do: ImagePipe.Run.run(resolve(config), builder, input, options)

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
          Config.t() | atom(),
          ImagePipe.URL.t(),
          {:file | :binary | :source, binary()},
          Path.t(),
          keyword()
        ) :: {:ok, ImagePipe.Result.t()} | {:error, term()}
  def write(config, builder, input, path, options \\ []),
    do: ImagePipe.Run.write(resolve(config), builder, input, path, options)

  # An instance name stands for the configuration the running instance
  # published. It raises when the instance isn't running.
  defp resolve(%Config{} = config), do: config
  defp resolve(name) when is_atom(name), do: Config.fetch_instance!(name, nil)
end

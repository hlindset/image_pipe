defmodule ImagePipe.URL do
  @moduledoc """
  Builds processing plans and generates signed ImagePipe URLs.

      config = ImagePipe.URL.config(keys: [signing_key], base_url: "https://cdn.example.com/images")

      builder =
        ImagePipe.URL.new(config)
        |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
        |> ImagePipe.URL.output(format: :webp, quality: 82)

      :ok = ImagePipe.URL.validate(builder)
      url = ImagePipe.URL.url!(builder, "images/cat.jpg")
      # "https://cdn.example.com/images/sig=…/w=400/h=300/fit=cover/anchor=smart/format=webp/q=82/src/images%2Fcat.jpg"

  A builder is an immutable value that holds a plan and a URL configuration.
  Every call returns a new builder, so a builder can be shared and extended
  with ordinary functions. Building and generating URLs reads no source,
  image, or cache.

  An app that serves its own URLs passes the same configuration to
  `ImagePipe.config(url: config, ...)`. Preset definitions belong to the
  server, and URLs carry only preset names. An app that builds URLs for an
  image service running elsewhere must match the settings listed in
  [Shared URL settings](https://hexdocs.pm/image_pipe/shared-url-settings.html).

  ## URL option names

  Builder options are the URL options with longer names. The URL syntax and
  each option's effect are documented in
  [Requesting images](https://hexdocs.pm/image_pipe/requesting-images.html)
  and the processing pages it links to, with an Elixir example for each
  option.

  A URL option with a hyphen uses an underscore in the builder, as in
  `extend-at` and `extend_at:`. These names differ:

  | URL | Builder |
  | --- | --- |
  | `w`, `h`, `min-w`, `min-h` | `resize: [width:, height:, min_width:, min_height:]` |
  | `fit`, `enlarge`, `zoom` | `resize: [fit:, enlarge:, zoom:]` |
  | `pad` | `padding:` |
  | `bg` | `background:` |
  | `preset` | `presets:` |
  | `wm`, `wm-src64` | `watermark:`, `watermark_source:` |
  | `wm-opacity` and other `wm-` options | `watermark_opacity:` and other `watermark_` options |
  | `cb` | `cachebuster:` in `new/1` |
  | `output` | `terminal:` |
  | `q`, `format-q` | `quality:`, `format_qualities:` |
  | `meta` | `metadata:` |
  | `profile` | `color_profile:` |
  | `progressive` in `jpeg-options` | `interlace:` |
  | `subsample` in `jpeg-options` and `avif-options` | `subsample_mode:` |

  Named values are atoms, with an underscore for a hyphen: `anchor=top-left`
  is `anchor: :top_left`. These values differ:

  | URL | Builder |
  | --- | --- |
  | `flip=h`, `v`, `hv` | `flip: :horizontal`, `:vertical`, `:both` |
  | `trim-symmetry=h`, `v`, `hv` | `trim_symmetry: :horizontal`, `:vertical`, `:both` |
  | `profile=preserve` | `color_profile: :preserve_source` |
  | `profile=srgb`, `display-p3`, `adobe-rgb` | `color_profile: {:convert, :srgb}`, `{:convert, :display_p3}`, `{:convert, :adobe_rgb}` |
  | `hdr=tonemap` | `hdr: :tone_map` |
  | `output=info,blurhash` | `terminal: {:info, [:blurhash]}` |
  | `wm-src64=<base64>` | `watermark_source: "logos/mark.png"`, the plain source |

  An option with several comma-separated values in the URL, such as
  `gradient`, takes a keyword list, as in
  `gradient: [opacity: 0.8, color: "black", direction: :left]`. With
  `encrypt_source: true` in the configuration, `watermark_source:` is
  written as `wm-enc`. Lengths, percentages, and colors are described under
  [option values](https://hexdocs.pm/image_pipe/requesting-images.html#option-values).
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.API, ImagePipe.Plan, ImagePipe.Security],
    exports: [Config]

  alias ImagePipe.API.URL, as: Generator
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Spec.Issue
  alias ImagePipe.Security
  alias ImagePipe.URL.Config

  @enforce_keys [:plan, :config]
  @derive {Inspect, except: [:config]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{plan: Plan.t(), config: Config.t()}

  @doc """
  Builds a URL configuration for `new/1`.

      config =
        ImagePipe.URL.config(
          base_url: "https://cdn.example.com/images",
          keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
        )

  An app that serves its own URLs passes the same value to
  `ImagePipe.config(url: config)`, so the server verifies signatures and
  decrypts sources with the same keys. Invalid
  options raise `ArgumentError`, and the message never includes a key.

  ## Options

  #{NimbleOptions.docs(Config.schema())}
  """
  @spec config(keyword()) :: Config.t()
  def config(options \\ []), do: Config.new!(options)

  @doc """
  Signs an existing mount-relative path with the first configured signing key.

  Returns `"/sig=<signature>" <> path`, preserving the exact path bytes without
  parsing, escaping, or normalizing them. Pass a config from `config/1`.
  The path must start with `/` and exclude any signature prefix, query string,
  or fragment. Source query parameters must already be escaped in the path.
  Raises `ArgumentError` for an invalid path shape or missing signing keys.

  Prepend the mount prefix or hostname to the result yourself; `:base_url`
  is not applied. This function performs no source or cache I/O and does not
  validate processing options or encrypt sources.
  """
  @spec sign_path(String.t(), Config.t()) :: String.t()
  def sign_path(path, %Config{options: options}), do: Generator.sign_path(path, options)

  @doc """
  Encrypts a UTF-8 source with the configured source encryption keys.

  Returns `{:ok, token}`. Place the token after the `enc/` source marker and
  sign the complete path with `sign_path/2`. `url/3` does both.

  `:iv` overrides the configured `:iv_mode` with `:deterministic`, `:random`,
  or an explicit 16-byte binary, as in `url/3`.

  Returns `{:error, :source_encryption_disabled}` without
  `:source_encryption_keys`, `{:error, :invalid_source}` for an empty or
  non-UTF-8 source, and `{:error, :invalid_encryption_options}` for any other
  option or a malformed `:iv`.
  """
  @spec encrypt_source(String.t(), Config.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def encrypt_source(source, %Config{options: options}, encryption_options \\ []),
    do: Security.encrypt_source(source, options, encryption_options)

  @doc """
  Generates the URL for a builder's plan and a source.

      {:ok, url} = ImagePipe.URL.url(builder, "photos/cat.jpg")
      url
      #=> "/images/w=400/src/photos%2Fcat.jpg"

  The source is the identifier the image service resolves: a path, an HTTP(S)
  URL, an S3 identifier, or a custom scheme. Pass it as a UTF-8 string,
  unescaped and with any query parameters, such as
  `"https://assets.example.com/cat.jpg?v=2"`. `url/3` escapes it once. A
  leading `/` is removed unless the source starts with `//` or the rest is a
  URL such as `/https://…`. The sources `.` and `..` are written with the
  `src64/` marker, because browsers resolve them as path segments. The
  `{:file, path}` and `{:binary, bytes}` inputs of `ImagePipe.run/4` have no
  URL.

  The URL is the configuration's `:base_url`, then `/sig=<signature>` when
  the configuration has `:keys`, then the options and the source. The
  signature covers everything after it, so a URL keeps a valid signature
  when served under another `:base_url`. The same plan, source, and
  configuration always give the same URL, whatever order the options were
  given in. Preset names stay in the URL as names, and the server resolves
  their current definitions.

  An `:expires` set with `new/1` is part of the URL. Computing a new expiry
  on every call gives a new URL every time. `url/3` doesn't compare the expiry
  with the current time.

  ## Options

    * `:iv` - with `encrypt_source: true`, overrides the configured `:iv_mode`
      for this URL. `:deterministic` and `:random` work as the `:iv_mode`
      values. A 16-byte binary is used as the IV of the main source, and each
      watermark source derives its own IV from it. An explicit IV must be
      unpredictable, or derived from the complete source with a secret key,
      and must never be used for two different sources under the same key.

  ## Return values

    * `{:ok, url}`.
    * `{:error, {:invalid_request, issues}}` - the configuration has
      `:mount_presets` and the plan fails `validate/1`. Without
      `:mount_presets`, the server checks the plan when it serves the URL.
    * `{:error, :invalid_source}` - the source is empty or not valid UTF-8.
    * `{:error, :too_many_options}` - the plan has more than 64 option and
      `-` segments, the most the server accepts.
    * `{:error, :source_encryption_disabled}` - a valid `:iv` was given and
      the configuration doesn't have `encrypt_source: true`.
    * `{:error, :invalid_encryption_options}` - an option other than `:iv`,
      or a malformed `:iv`.
  """
  @spec url(t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, atom() | {:invalid_request, [Issue.t()]}}
  def url(%__MODULE__{plan: plan, config: config}, source, options \\ []),
    do: Generator.build(plan, source, config.options, options)

  @doc """
  Like `url/3`, but returns the URL or raises `ArgumentError`.

  The message never includes the source or a key.
  """
  @spec url!(t(), String.t(), keyword()) :: String.t()
  def url!(builder, source, options \\ []) do
    case url(builder, source, options) do
      {:ok, url} ->
        url

      {:error, _reason} ->
        raise ArgumentError, "cannot build URL from the given plan and source"
    end
  end

  @doc """
  Starts a builder with an empty plan.

      ImagePipe.URL.new()
      ImagePipe.URL.new(config)
      ImagePipe.URL.new(config, filename: "cat", expires: 1_767_225_600)
      ImagePipe.URL.new(filename: "cat")

  `config` comes from `config/1`. Without it, the builder uses
  `config([])`: no base URL, signing, or encryption. The options are request
  controls, which apply once to the whole request. An empty plan is valid.
  Its URL, such as `/src/cat.jpg`, serves the original in a negotiated
  format.

  ## Options

  Each option also accepts `:unset`, which removes a value set by a preset or
  the server's request defaults. An unknown, repeated, or malformed option
  raises `ArgumentError`.

  #{NimbleOptions.docs(ImagePipe.Plan.request_schema())}
  """
  @spec new(Config.t() | keyword()) :: t()
  def new(options \\ [])
  def new(%Config{} = config), do: new(config, [])
  def new(options) when is_list(options), do: new(config(), options)

  @doc "Like `new/1`, with a configuration and request controls."
  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, options),
    do: %__MODULE__{plan: Plan.new(options), config: config}

  @doc """
  Appends a processing group to the plan.

      ImagePipe.URL.new()
      |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
      |> ImagePipe.URL.group(padding: 12, background: "white")
      # "/w=400/h=300/fit=cover/anchor=smart/-/pad=12,12,12,12/bg=ffffff/src/…"

  The options of one call form one group, like the options between two `-`
  segments in a URL. They run in the fixed
  [processing order](https://hexdocs.pm/image_pipe/processing.html#processing-order),
  whatever order they're given in. A second call starts a new group that
  processes the previous group's result, with fresh settings: a `dpr: 2` in
  the first group doesn't apply to the second.

  Resize options go in a `resize:` keyword list. `presets:` names presets to
  apply to this group, and the group's own options override them. Option
  names and values are listed under
  [URL option names](#module-url-option-names).

  Any option, including each `resize:` option, accepts `:unset` to remove a
  value set by the group's presets or the server's request defaults.

  Each value is checked here. An unknown option, a repeated key, a malformed
  value, or a group with no options raises `ArgumentError`. Checks that
  involve several options, such as `fit: :cover` without a width or height,
  happen in `validate/1`.
  """
  @spec group(t(), keyword()) :: t()
  def group(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.group(builder.plan, options)}

  @doc """
  Sets output and encoding options for the whole request.

      builder
      |> ImagePipe.URL.output(format: :webp, quality: 82)
      |> ImagePipe.URL.output(quality: 60)
      # "/…/format=webp/q=60/src/…"

  The options are the [output and encoding](https://hexdocs.pm/image_pipe/output.html)
  options of the URL, under the names listed under
  [URL option names](#module-url-option-names).
  Each call merges its options into the plan. An option given again replaces
  its whole previous value, including every entry of `jpeg_options:` or
  `format_qualities:`. Options not given keep their value.

  An option the plan doesn't set takes the server's configured default when
  the URL is served. `:unset` removes a value set by a preset or the request
  defaults, so the configured default applies. `format_qualities:` and the
  encoder options such as `jpeg_options:` need at least one entry. Clear them
  with `:unset`. A malformed value raises `ArgumentError`.
  """
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.output(builder.plan, options)}

  @doc """
  Checks the plan as the server would, without generating a URL.

      ImagePipe.URL.new(ImagePipe.url_config(config))
      |> ImagePipe.URL.group(resize: [fit: :cover])
      |> ImagePipe.URL.validate()
      # {:error,
      #  [%ImagePipe.Plan.Spec.Issue{reason: :inert_option,
      #     locations: [{:group, 0, :fit}], detail: {:requires, :resize}}]}

  Returns `:ok` or `{:error, issues}`, a list of `ImagePipe.Plan.Spec.Issue`
  structs. The check applies the server's request defaults and the presets the
  plan names, then checks how the options combine: options that need another
  option, options that conflict, and options that have no effect, such as
  `fit: :cover` without a width or height. It reads no source or cache, so a
  plan that passes can still fail on a particular image.

  The check needs `:mount_presets` in the URL configuration. Without it,
  `validate/1` returns `:ok`. With `preset_lookup: true`, only the server can
  resolve a preset missing from `:presets`, and that preset can set any
  option of its group and of the request. For a plan that names one, the
  check skips the groups that name it and the request-wide options, and
  checks the other groups. In an app that serves its own URLs,
  `ImagePipe.validate/2` runs the full check, including the lookup.
  """
  @spec validate(t()) :: :ok | {:error, [Issue.t()]}
  def validate(%__MODULE__{plan: plan, config: %Config{options: options}}),
    do: Generator.check(plan, options)
end

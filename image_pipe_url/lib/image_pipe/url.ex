defmodule ImagePipe.URL do
  @moduledoc """
  Builds processing plans and generates signed ImagePipe URLs.

  Use the builder API to construct an immutable builder with typed options:

      config = ImagePipe.URL.config(keys: [signing_key], base_url: "https://cdn.example.com/images")

      builder =
        ImagePipe.URL.new(config)
        |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
        |> ImagePipe.URL.output(format: :webp, quality: 82)

      :ok = ImagePipe.URL.validate(builder)
      url = ImagePipe.URL.url!(builder, "images/cat.jpg")

  Each group runs in the fixed processing order documented in the API contract.
  Append another group to process the previous group's result.

  URL generation performs no source, image, or cache I/O. The serving mount
  takes the same configuration through `ImagePipe.config(url: config, ...)`.
  A builder app and a separate image service must use identical signing keys.
  Preset definitions belong to the image service; URLs carry their names.
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
  Builds reusable, redacted URL configuration.

  Owns signing, source encryption, and the URL prefix. Preset definitions
  belong to the serving configuration (`ImagePipe.config/1`); URLs carry only
  preset names.

  `:base_url` is an optional HTTP(S) URL or path prefix, such as
  `"https://cdn.example.com/images"` or `"/images"`. Mount path segments must
  use unescaped ASCII letters, digits, `-`, `.`, `_`, or `~`.

  `:keys` is the mount's ordered list of hex-encoded signing keys. Generation
  uses the first key. Omit keys for unsigned URLs. Invalid configuration raises
  `ArgumentError` without including credentials in the message.

  `:mount_presets` optionally describes the serving mount's presets so the
  builder can check plans; it never changes generated URLs. It accepts
  `:presets` and `:request_defaults` as on `ImagePipe.config/1`, and
  `preset_lookup: true` when the mount has a lookup. Without it, `url/3` and
  `validate/1` check values only. Apps that serve their own URLs get it filled
  in by `ImagePipe.url_config/1`. A copy must match the mount; a stale one
  gives wrong validation results.

  `:encrypt_source` defaults to `false`. Set it to `true` with independent
  `:source_encryption_keys` (ordered raw 32-byte binaries) to conceal the source.
  Signing keys are required. `:iv_mode` is `:deterministic` (default) or `:random`.
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

  Returns the token only. Place it after the `enc/` source marker and sign the
  complete request path. Prefer `url/3`, which does both.

  `:iv` overrides the configured `:iv_mode` with `:deterministic`, `:random`,
  or an explicit 16-byte binary. Explicit IVs must be unpredictable or
  secret-keyed over the complete source and never reused for different sources
  under the same key.
  """
  @spec encrypt_source(String.t(), Config.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def encrypt_source(source, %Config{options: options}, encryption_options \\ []),
    do: Security.encrypt_source(source, options, encryption_options)

  @doc """
  Generates a stable URL using the builder's plan and configuration.

  The source is a UTF-8 string, including any source query parameters. Source
  bytes are escaped once and the signature covers the mount-relative path.
  Ordinary root-relative sources accept an optional leading `/`; it is removed
  before escaping, encryption, and signing.
  Construction performs no source, image, or cache I/O. Files and binary input
  tuples accepted by `ImagePipe.run/4` have no URL representation.

  Preset names remain references in generated URLs. Explicit options, including
  false and identity values, are retained as overrides. With `:mount_presets`,
  the combined request is validated like `validate/1`; otherwise the mount
  validates it. An `:unset` option is written as `key=unset`.

  With encrypted configuration, per-call `:iv` accepts `:deterministic`,
  `:random`, or an explicit 16-byte binary. An explicit IV must be unpredictable
  or derived from the complete source with a secret key; do not reuse it for
  different sources under the same key. An explicit IV encrypts the main
  source; each watermark source derives its own IV from it with the secret
  key. The default derives the IV safely. Random mode produces a fresh URL. Deterministic encryption reveals source
  equality; both modes reveal the padded source length.

  An explicit `:expires` value is stable; computing a new expiry for each call
  deliberately changes the URL.
  """
  @spec url(t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, atom() | {:invalid_request, [Issue.t()]}}
  def url(%__MODULE__{plan: plan, config: config}, source, options \\ []),
    do: Generator.build(plan, source, config.options, options)

  @doc """
  Like `url/3`, returning the URL or raising `ArgumentError`.

  Errors omit the source and credentials.
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
  Starts an empty builder with optional configuration or request controls.

  `new(config)` reuses a value from `config/1`. Use `new(config, options)`
  to supply request controls as well. `new()` uses default configuration.

  Accepts `:orient` (`:auto` or `:none`), `:page` (a 0-based page or
  frame), `:filename`, `:attachment`, `:cachebuster`, `:expires` (positive
  Unix seconds), and `:debug`. Each also accepts `:unset`.
  Unknown, duplicate, or malformed options raise `ArgumentError`.
  """
  @spec new(Config.t() | keyword()) :: t()
  def new(options \\ [])
  def new(%Config{} = config), do: new(config, [])
  def new(options) when is_list(options), do: new(config(), options)

  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, options),
    do: %__MODULE__{plan: Plan.new(options), config: config}

  @doc """
  Appends a processing group. Options in the group have fixed execution order.

  `presets: [...]` names presets that apply to this group, in precedence
  order; the group's explicit options override them.
  Resize settings use `resize: [width: 400, height: :auto, fit: :contain]`.
  Geometry uses numbers for pixels or `{:pct, value}` for percentages. Colors
  accept RGB tuples, CSS names, or hex strings. Effects and encoder policies
  use typed values; see `docs/elixir-api.md` for the complete option shapes.

  Any option, including each resize setting, accepts `:unset` to clear a value
  set by the group's presets or the request defaults.

  Values are checked immediately and malformed options raise `ArgumentError`.
  Use `validate/1` to check dependencies and conflicts across the plan.
  """
  @spec group(t(), keyword()) :: t()
  def group(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.group(builder.plan, options)}

  @doc """
  Merges explicit output settings into a plan.

  Supports terminal selection, format, quality, color/metadata policy, output
  DPI, quality search, byte limits, and encoder options. Repeating an output call replaces
  each supplied option as a whole; omitted options retain their previous value.
  Host-dependent defaults remain unresolved. Any option accepts `:unset` to
  restore the host configuration over presets and request defaults; encoder
  options and format qualities need at least one entry otherwise. Malformed
  values raise `ArgumentError`.
  """
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.output(builder.plan, options)}

  @doc """
  Checks semantic constraints without fetching a source or accessing a cache.

  Returns `:ok` or `{:error, issues}`. Each issue identifies typed option
  locations, a reason, and constraint details. Explicit no-op options are
  checked before normalization, including applicability to the selected output.

  Semantic checks need `:mount_presets` in the URL configuration; without it
  this returns `:ok`. With it, request defaults, known presets, and explicit
  options are checked together. A name the known presets lack is an unknown
  preset, unless the mount has a lookup, which then decides at request time.
  """
  @spec validate(t()) :: :ok | {:error, [Issue.t()]}
  def validate(%__MODULE__{plan: plan, config: %Config{options: options}}),
    do: Generator.check(plan, options)
end

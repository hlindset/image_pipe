defmodule ImagePipe do
  @moduledoc """
  The Elixir API for building processing plans, executing them, and generating URLs.

  Use the builder API to construct an immutable builder with typed options:

      plan =
        ImagePipe.new()
        |> ImagePipe.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart)
        |> ImagePipe.output(format: :webp, quality: 82)

      :ok = ImagePipe.validate(plan)

  Each group runs in the fixed processing order documented in the API contract.
  Append another group to process the previous group's result. The builder keeps
  its processing plan separate from reusable host configuration. Pass a config
  built with `config/1` to `new/1` to share sources and caches with a Plug mount.
  """

  use Boundary,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.API,
      ImagePipe.Error,
      ImagePipe.Execution,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Processing,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [Plug, Result]

  alias ImagePipe.Config
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Request.Issue

  @enforce_keys [:plan, :config]
  @derive {Inspect, except: [:config]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{plan: Plan.t(), config: Config.t()}

  @doc """
  Builds reusable, redacted host configuration for the builder and Plug.

  Owns sources, caches, processing defaults, limits, storage partitions, signing,
  source encryption, and URL generation defaults.

  `:base_url` is an optional HTTP(S) URL or path prefix, such as
  `"https://cdn.example.com/images"` or `"/images"`. Mount path segments must
  use unescaped ASCII letters, digits, `-`, `.`, `_`, or `~`.

  `:keys` is the mount's ordered list of hex-encoded signing keys. Generation
  uses the first key. Omit keys for unsigned URLs. Invalid configuration raises
  `ArgumentError` without including credentials in the message.

  `:encrypt_source` defaults to `false`. Set it to `true` with independent
  `:source_encryption_keys` (ordered raw 32-byte binaries) to conceal the source.
  Signing keys are required. `:iv_mode` is `:deterministic` (default) or `:random`.
  """
  @spec config(keyword()) :: Config.t()
  def config(options \\ []), do: Config.new!(options)

  @doc """
  Generates a stable URL using the builder's plan and shared configuration.

  The source is a UTF-8 string, including any source query parameters. Source
  bytes are escaped once and the signature covers the mount-relative path.
  Construction performs no source, image, or cache I/O. Files and binary input
  tuples accepted by `run/3` have no URL representation.

  With encrypted configuration, per-call `:iv` accepts `:deterministic`,
  `:random`, or an explicit 16-byte binary. An explicit IV must be unpredictable
  or derived from the complete source with a secret key; do not reuse it for
  different sources under the same key. The default derives the IV safely.
  Random mode produces a fresh URL. Deterministic encryption reveals source
  equality; both modes reveal the padded source length.

  An explicit `:expires` value is stable; computing a new expiry for each call
  deliberately changes the URL. Use the same processing defaults on the mount
  and in direct execution when identical output is required.
  """
  @spec url(t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, atom() | {:invalid_request, [Issue.t()]}}
  def url(%__MODULE__{plan: plan, config: config}, source, options \\ []),
    do: ImagePipe.API.url(plan, source, config.options, options)

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
  Starts an empty builder with optional shared configuration or request controls.

  `new(config)` reuses a value from `config/1`. Use `new(config, options)`
  to supply request controls as well. `new()` uses default configuration.

  Accepts `:orient` (`:auto` or `:none`), `:filename`, `:attachment`,
  `:cachebuster`, `:expires` (positive Unix seconds), and `:debug`.
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

  Resize settings use `resize: [width: 400, height: :auto, fit: :contain]`.
  Geometry uses numbers for pixels or `{:pct, value}` for percentages. Colors
  accept RGB tuples, CSS names, or hex strings. Effects and encoder policies
  use typed values; see `docs/elixir-api.md` for the complete option shapes.

  Values are checked immediately and malformed options raise `ArgumentError`.
  Use `validate/1` to check dependencies and conflicts across the plan.
  """
  @spec group(t(), keyword()) :: t()
  def group(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.group(builder.plan, options)}

  @doc """
  Merges explicit output settings into a plan.

  Supports terminal selection, format, quality, color/metadata policy, quality
  search, byte limits, and encoder options. Repeating an output call replaces
  each supplied option as a whole; omitted options retain their previous value.
  Host-dependent defaults remain unresolved. Malformed values raise `ArgumentError`.
  """
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = builder, options),
    do: %{builder | plan: Plan.output(builder.plan, options)}

  @doc """
  Checks semantic constraints without fetching a source or accessing a cache.

  Returns `:ok` or `{:error, issues}`. Each issue identifies typed option
  locations, a reason, and constraint details. Explicit no-op options are
  checked before normalization, including applicability to the selected output.
  """
  @spec validate(t()) :: :ok | {:error, [Issue.t()]}
  def validate(%__MODULE__{plan: plan}), do: Plan.validate(plan)

  @doc """
  Executes a plan and returns a fully consumed `ImagePipe.Result`.

  Inputs are `{:file, path}`, `{:binary, bytes}`, or `{:source, source_string}`.
  Configured sources use the builder's sources, input/output caches, processing
  defaults, detector, limits, and telemetry. Per-call host options override the
  reusable configuration. File and binary inputs bypass both caches.
  `accept: "image/webp"` supplies optional format negotiation preferences.

  `request_inputs: [headers: [{"x-tenant", "one"}], cookies: %{"session" => "abc"}]`
  supplies values named by `storage_inputs`, matching HTTP cache partitions.
  These values affect storage identity; source adapters use their own settings.

  Returns `{:ok, result}` or a tagged runtime error. Invalid configuration
  raises `ArgumentError`. All lazy pixel and encoding work finishes before
  source resources are closed.
  """
  @spec run(t(), {:file | :binary | :source, binary()}, keyword()) ::
          {:ok, ImagePipe.Result.t()} | {:error, term()}
  def run(plan, input, options \\ []), do: ImagePipe.Run.run(plan, input, options)

  @doc """
  Runs a plan, then writes the complete result to a file.

  Returns the same result as `run/3`. Info results are serialized as JSON.
  An existing file is overwritten. Write failures return
  `{:error, {:destination, reason}}` after all source resources are released.
  """
  @spec write(t(), {:file | :binary | :source, binary()}, Path.t(), keyword()) ::
          {:ok, ImagePipe.Result.t()} | {:error, term()}
  def write(plan, input, path, options \\ []),
    do: ImagePipe.Run.write(plan, input, path, options)
end

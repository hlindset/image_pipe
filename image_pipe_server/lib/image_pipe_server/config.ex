defmodule ImagePipeServer.Config do
  @moduledoc """
  Loads and validates the server configuration at boot.

  The configuration tree comes from the TOML file and `IPS_` environment
  variables (see `ImagePipeServer.Config.Tree`). Each section converts to the
  options the library already validates:

    * `[server]` - the listener: `port`, `bind`, `mount_path`,
      `shutdown_timeout`, `read_timeout`, `max_connections`, and an optional
      `auth_token` that image requests must send as a bearer token.
    * `[url]` - the signing and source-encryption options of
      `ImagePipe.config/1`. `base_url`, `encrypt_source`, and `iv_mode` only
      affect URL generation and are not accepted.
    * `[sources.<name>]` - named sources
      (see `ImagePipeServer.Config.Sources`).
    * `[cache]` - `output` and `input` `ImagePipe.Cache.FileSystem` caches, and
      `storage_inputs` as `[{ header = "..." }, { cookie = "..." }]`.
    * `[processing]` - the processing options of `ImagePipe.config/1`,
      including `watermarks.<name>` asset tables, `request_watermarks`,
      `presets.<name>` option fragments, `request_defaults`, and
      `detector_warmup`, the instance option of `ImagePipe`.
    * `[pool]` - `ImagePipe.ProcessingPool` options. `max_concurrency`
      defaults to the VM's online schedulers.
    * `[http]` - the delivery options of `ImagePipe.Plug.init/1`.
    * `[telemetry]` - `log_level` is the lowest level the server logs.
      `log_requests` attaches the default Logger. `trust_traceparent`
      continues an inbound W3C `traceparent` when tracing is on, and
      `trust_request_id` keeps an inbound `x-request-id`.

  Invalid configuration raises `ImagePipeServer.ConfigError` (see there for
  which values a message may quote).
  """

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipeServer.Config.Convert
  alias ImagePipeServer.Config.Sources
  alias ImagePipeServer.Config.Tree
  alias ImagePipeServer.ConfigError

  @enforce_keys [
    :server,
    :trust_traceparent,
    :trust_request_id,
    :image_pipe,
    :detector_warmup,
    :http,
    :pool,
    :log_level,
    :telemetry,
    :credential_warmups
  ]
  defstruct @enforce_keys

  @typedoc """
  The validated configuration.

    * `:server` - `:port`, `:ip`, `:mount_path`, `:shutdown_timeout`,
      `:read_timeout`, `:max_connections`, and `:auth_token_hash`, the SHA-256
      of the auth token (or `nil`). The token itself isn't kept.
    * `:trust_request_id` - whether a request keeps an inbound
      `x-request-id`.
    * `:trust_traceparent` - whether the tracer continues an inbound
      `traceparent` (its `extract_inbound` option).
    * `:image_pipe` - the `ImagePipe.Config` the server's instance runs.
    * `:detector_warmup` - which detector classes the instance loads models
      for at boot: `:all`, `false`, or a list of class names.
    * `:http` - the delivery options of `ImagePipe.Plug.init/1`.
    * `:pool` - `ImagePipe.ProcessingPool` options with the pool's name.
    * `:log_level` - the lowest level the server logs.
    * `:telemetry` - default Logger options when requests are logged, or
      `nil`.
    * `:credential_warmups` - `ImagePipe.Source.S3.CredentialWarmup` options,
      one per named S3 bucket whose credentials come from a provider.
  """
  @type t :: %__MODULE__{
          server: keyword(),
          trust_traceparent: boolean(),
          trust_request_id: boolean(),
          image_pipe: ImagePipe.Config.t(),
          detector_warmup: :all | false | [String.t()],
          http: keyword(),
          pool: keyword(),
          log_level: Logger.level(),
          telemetry: keyword() | nil,
          credential_warmups: [keyword()]
        }

  @pool ImagePipeServer.ProcessingPool

  @server_schema [
    port: [type: {:in, 0..65_535}, default: 8080],
    bind: [type: :string, default: "0.0.0.0"],
    mount_path: [type: :string, default: "/"],
    shutdown_timeout: [type: :non_neg_integer, default: 15_000],
    read_timeout: [type: :pos_integer, default: 10_000],
    max_connections: [type: :pos_integer, default: 2048],
    auth_token: [type: :string]
  ]

  @telemetry_schema [
    log_level: [type: {:in, Logger.levels()}, default: :info],
    log_requests: [type: :boolean, default: false],
    trust_traceparent: [type: :boolean, default: false],
    trust_request_id: [type: :boolean, default: false]
  ]

  @watermark_schema [
    source: [type: :string, required: true],
    opacity: [type: :float, default: 1.0]
  ]

  @doc "Reads, converts, and validates the configuration."
  @spec load!(%{String.t() => String.t()}, Path.t()) :: t()
  def load!(env, default_path) do
    env
    |> Tree.read!(default_path)
    |> options!()
    |> Keyword.replace_lazy(:sources, &Sources.with_aws_environment(&1, env))
    |> build!()
  end

  @doc "Converts the configuration tree to per-section options."
  @spec options!(Tree.t()) :: keyword()
  def options!(tree) do
    Convert.options!(tree, schema(), [])
  end

  @doc """
  The schema the loader converts the tree with, one table per section.
  `ImagePipeServer.Config.Reference` renders it as documentation.
  """
  @spec schema() :: keyword()
  def schema do
    [
      server: [type: Convert.table(@server_schema)],
      url: [type: Convert.table(url_schema())],
      sources: [type: {:convert, &Sources.convert/2, :sources}],
      cache: [type: {:convert, &cache/2, cache_schema()}],
      processing: [type: Convert.table(processing_schema())],
      pool: [type: Convert.table(pool_schema())],
      http: [type: Convert.table(http_schema())],
      telemetry: [type: Convert.table(@telemetry_schema)]
    ]
  end

  # The server never builds URLs, so the builder-only settings are left out.
  defp url_schema do
    ImagePipe.Security.options_schema()
    |> Keyword.drop([:encrypt_source, :iv_mode])
    |> Keyword.merge(
      keys: [type: {:list, {:convert, &signing_key/2, "hex strings"}}, default: []],
      source_encryption_keys: [
        type: {:list, {:convert, &encryption_key/2, "hex strings, each a 32-byte key"}},
        default: []
      ]
    )
  end

  defp signing_key(value, path) do
    with {:ok, key} <- Convert.string(value, path) do
      case Base.decode16(key, case: :mixed) do
        {:ok, <<_::binary-size(1), _rest::binary>>} -> {:ok, key}
        _invalid -> {:error, path, "expected a non-empty hex string"}
      end
    end
  end

  # Checked here so the error names the setting. The library decodes the key.
  defp encryption_key(value, path) do
    with {:ok, key} <- Convert.string(value, path) do
      case Base.decode16(key, case: :mixed) do
        {:ok, <<_::binary-size(32)>>} -> {:ok, key}
        _invalid -> {:error, path, "expected a hex-encoded 32-byte key"}
      end
    end
  end

  defp cache_schema do
    [
      output: [type: {:convert, &file_system(&1, output_schema(), &2), output_schema()}],
      input: [type: {:convert, &file_system(&1, store_schema(), &2), store_schema()}],
      storage_inputs: [type: {:list, {:tuple, [{:in, [:header, :cookie]}, :string]}}]
    ]
  end

  defp cache(value, path) do
    with {:ok, options} <- Convert.options(value, cache_schema(), path) do
      {:ok,
       Enum.map(options, fn
         {:output, cache} -> {:cache, cache}
         {:input, cache} -> {:input_cache, cache}
         other -> other
       end)}
    end
  end

  defp file_system(value, schema, path) do
    with {:ok, options} <- Convert.options(value, schema, path),
         {:ok, options} <- Convert.require_keys(options, [:root], path),
         do: {:ok, {FileSystem, options}}
  end

  defp store_schema do
    Store.options_schema()
    |> Keyword.delete(:pool)
    |> Keyword.merge(
      root: [type: {:convert, &cache_root/2, "string (absolute path)"}, required: true],
      window_ratio: [type: :float],
      doorkeeper_fpr: [type: :float]
    )
  end

  defp cache_root(value, path) do
    case Convert.string(value, path) do
      {:ok, root} = ok -> if Path.type(root) == :absolute, do: ok, else: absolute_path(path)
      {:error, _path, _message} -> absolute_path(path)
    end
  end

  defp absolute_path(path), do: {:error, path, "expected an absolute path"}

  defp output_schema, do: store_schema() ++ ImagePipe.Cache.shared_options_schema()

  # The library applies these defaults after validation, so its schema
  # doesn't carry them; they are added here for the reference.
  defp processing_schema do
    defaults = ImagePipe.Processing.Config.resolve!([])

    ImagePipe.Processing.Config.schema()
    |> Keyword.drop([:sources, :processing_pool])
    |> elixir_only([:clock, :telemetry_prefix, :preset_lookup, :max_preset_lookups])
    |> Enum.map(fn {key, spec} ->
      case Keyword.fetch(defaults, key) do
        {:ok, default} -> {key, Keyword.put_new(spec, :default, default)}
        :error -> {key, spec}
      end
    end)
    |> Keyword.merge(
      source_cache_policy: [type: Sources.cache_policy_type()],
      format_order: [type: {:list, {:in, ImagePipe.Format.modern_formats()}}],
      jpeg_options: [type: Convert.table(JpegOptions.schema())],
      png_options: [type: Convert.table(PngOptions.schema())],
      webp_options: [type: Convert.table(WebpOptions.schema())],
      avif_options: [type: Convert.table(AvifOptions.schema())],
      watermarks: [type: {:map, :string, Convert.table(@watermark_schema)}],
      request_watermarks: [type: :boolean, default: false],
      presets: [type: {:map, :string, :string}],
      request_defaults: [type: :string],
      detector_warmup: [
        type: {:convert, &detector_warmup/2, ~s(`"all"` or `false` or array of string)},
        default: :all
      ]
    )
  end

  # Convert skips boolean choices, so `false` is matched on its own.
  defp detector_warmup(value, path) do
    case Convert.value(:boolean, value, path) do
      {:ok, false} -> {:ok, false}
      _not_false -> Convert.value({:or, [{:in, [:all]}, {:list, :string}]}, value, path)
    end
  end

  defp pool_schema do
    ImagePipe.ProcessingPool.options_schema()
    |> Keyword.delete(:name)
    |> Keyword.update!(:max_concurrency, &Keyword.delete(&1, :required))
  end

  defp http_schema, do: ImagePipe.Plug.Config.options_schema()

  defp elixir_only(schema, keys) do
    Enum.reduce(keys, schema, &Keyword.put(&2, &1, type: :any))
  end

  @doc "Validates converted options with the library and builds the server configuration."
  @spec build!(keyword()) :: t()
  def build!(sections) do
    pool = pool!(Keyword.get(sections, :pool))

    {detector_warmup, processing} =
      sections |> Keyword.get(:processing, []) |> Keyword.pop(:detector_warmup, :all)

    image_pipe = image_pipe!(Keyword.put(sections, :processing, processing), pool)
    instance!(image_pipe, detector_warmup)

    %__MODULE__{
      server: server!(Keyword.get(sections, :server, [])),
      trust_traceparent: trust_traceparent(Keyword.get(sections, :telemetry, [])),
      trust_request_id:
        Keyword.get(Keyword.get(sections, :telemetry, []), :trust_request_id, false),
      image_pipe: image_pipe,
      detector_warmup: detector_warmup,
      http: http!(Keyword.get(sections, :http, [])),
      pool: pool,
      log_level: Keyword.get(Keyword.get(sections, :telemetry, []), :log_level, :info),
      telemetry: telemetry(Keyword.get(sections, :telemetry, [])),
      credential_warmups: credential_warmups(Keyword.get(sections, :sources, []))
    }
  end

  defp server!(options) do
    # Validated apart from the schema, whose errors would quote the token.
    {auth_token, options} = Keyword.pop(options, :auth_token)
    options = validate!(options, Keyword.delete(@server_schema, :auth_token), "server")

    [
      port: Keyword.fetch!(options, :port),
      ip: ip!(Keyword.fetch!(options, :bind)),
      mount_path: mount_path!(Keyword.fetch!(options, :mount_path)),
      shutdown_timeout: Keyword.fetch!(options, :shutdown_timeout),
      read_timeout: Keyword.fetch!(options, :read_timeout),
      max_connections: Keyword.fetch!(options, :max_connections),
      auth_token_hash: auth_token_hash!(auth_token)
    ]
  end

  defp auth_token_hash!(nil), do: nil

  defp auth_token_hash!(""),
    do:
      raise(ConfigError, "invalid configuration: server.auth_token: expected a non-empty string")

  defp auth_token_hash!(token), do: :crypto.hash(:sha256, token)

  defp ip!(bind) do
    case :inet.parse_address(String.to_charlist(bind)) do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        raise ConfigError, "invalid configuration: server.bind: expected an IP address"
    end
  end

  defp mount_path!("/" <> _rest = path), do: path

  defp mount_path!(_path),
    do:
      raise(
        ConfigError,
        "invalid configuration: server.mount_path: expected a path starting with /"
      )

  defp image_pipe!(sections, pool) do
    library!(fn ->
      shared =
        Keyword.get(sections, :url, []) ++
          processing(Keyword.get(sections, :processing, [])) ++
          Keyword.get(sections, :cache, []) ++
          sources(Keyword.get(sections, :sources)) ++
          processing_pool(pool)

      ImagePipe.config(shared)
    end)
  end

  # Checks warmup classes against the build's detector.
  defp instance!(image_pipe, detector_warmup) do
    library!(fn ->
      ImagePipe.child_spec(name: __MODULE__, config: image_pipe, detector_warmup: detector_warmup)
    end)
  end

  # Validates the mount options; the instance name is not looked up here.
  defp http!(options) do
    library!(fn -> ImagePipe.Plug.init([instance: __MODULE__] ++ options) end)
    options
  end

  # Watermark names are the operator's own identifiers, fixed at boot.
  defp processing(options) do
    case Keyword.fetch(options, :watermarks) do
      {:ok, watermarks} ->
        Keyword.put(
          options,
          :watermarks,
          Map.new(watermarks, fn {name, entry} -> {String.to_atom(name), entry} end)
        )

      :error ->
        options
    end
  end

  defp sources(nil), do: []
  defp sources(sources), do: [sources: sources]

  defp processing_pool(pool), do: [processing_pool: Keyword.fetch!(pool, :name)]

  # The library names the setting in its errors and keeps secret values out.
  # It names a source as `:name`, which the file spells `sources.name`.
  defp library!(fun) do
    fun.()
  rescue
    error in ArgumentError ->
      message =
        Regex.replace(
          ~r/\Ainvalid source :([a-z0-9_]+): /,
          error.message,
          "invalid configuration: sources.\\1: "
        )

      reraise ConfigError, [message: message], __STACKTRACE__
  end

  # The server always bounds processing, so a burst waits or gets a 503
  # instead of exhausting memory. The VM's online schedulers follow the
  # container's CPU quota.
  defp pool!(options) do
    options = Keyword.merge([max_concurrency: System.schedulers_online()], options || [])
    validate!([name: @pool] ++ options, ImagePipe.ProcessingPool.options_schema(), "pool")
  end

  # Credentials are scoped by bucket, so only named buckets can be warmed.
  defp credential_warmups(sources) do
    for {_name, mount} <- sources,
        Keyword.fetch!(mount, :adapter) == ImagePipe.Source.S3,
        options = Keyword.fetch!(mount, :options),
        default = Keyword.fetch!(options, :default),
        {bucket, overrides} <- Enum.sort(Keyword.get(options, :buckets, %{})),
        {:provider, provider, opts} <-
          [Keyword.get(overrides, :credentials, default[:credentials])],
        do: [provider: provider, opts: opts, scope: bucket]
  end

  defp trust_traceparent(options), do: Keyword.get(options, :trust_traceparent, false)

  # Request lines log at `info` and failures at `warning`, so `log_level`
  # can keep only the failures.
  defp telemetry(options) do
    if Keyword.get(options, :log_requests, false), do: [level: :info]
  end

  defp validate!(options, schema, section) do
    case NimbleOptions.validate(options, schema) do
      {:ok, options} ->
        options

      {:error, error} ->
        raise ConfigError, "invalid configuration: #{section}: #{Exception.message(error)}"
    end
  end
end

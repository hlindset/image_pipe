defmodule ImagePipeServer.Config do
  @moduledoc """
  Loads and validates the server configuration at boot.

  The configuration tree comes from the TOML file and `IPS_` environment
  variables (see `ImagePipeServer.Config.Tree`). Each section converts to the
  options the library already validates:

    * `[server]` - `port`, `bind`, and `mount_path`.
    * `[url]` - `ImagePipe.URL.config/1`. Source-encryption keys take a
      `base64:` or `hex:` prefix. `base_url` only affects URL generation and
      is not accepted.
    * `[sources.<name>]` - named source mounts
      (see `ImagePipeServer.Config.Sources`).
    * `[cache]` - `output` and `input` `ImagePipe.Cache.FileSystem` caches, and
      `storage_inputs` as `[{ header = "..." }, { cookie = "..." }]`.
    * `[processing]` - the processing options of `ImagePipe.config/1`.
    * `[pool]` - `ImagePipe.ProcessingPool` options.
    * `[http]` - the delivery options of `ImagePipe.Plug.init/1`.
    * `[telemetry]` - `log_level` attaches the default Logger.

  Invalid configuration raises `ImagePipeServer.ConfigError`, naming the
  setting but never its value.
  """

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipeServer.Config.Convert
  alias ImagePipeServer.Config.Sources
  alias ImagePipeServer.Config.Tree
  alias ImagePipeServer.ConfigError

  @enforce_keys [:server, :image_pipe, :pool, :telemetry]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          server: keyword(),
          image_pipe: keyword(),
          pool: keyword() | nil,
          telemetry: keyword() | nil
        }

  @server_schema [
    port: [type: :non_neg_integer, default: 8080],
    bind: [type: :string, default: "0.0.0.0"],
    mount_path: [type: :string, default: "/"]
  ]

  @telemetry_schema [log_level: [type: {:in, Logger.levels()}]]

  @doc "Reads, converts, and validates the configuration."
  @spec load!(%{String.t() => String.t()}, Path.t()) :: t()
  def load!(env, default_path) do
    env |> Tree.read!(default_path) |> options!() |> build!()
  end

  @doc "Converts the configuration tree to per-section options."
  @spec options!(Tree.t()) :: keyword()
  def options!(tree) do
    Convert.options!(tree, sections(), [])
  end

  defp sections do
    [
      server: [type: {:convert, &Convert.options(&1, @server_schema, &2)}],
      url: [type: {:convert, &Convert.options(&1, url_schema(), &2)}],
      sources: [type: {:convert, &Sources.convert/2}],
      cache: [type: {:convert, &cache/2}],
      processing: [type: {:convert, &Convert.options(&1, processing_schema(), &2)}],
      pool: [type: {:convert, &Convert.options(&1, pool_schema(), &2)}],
      http: [type: {:convert, &Convert.options(&1, http_schema(), &2)}],
      telemetry: [type: {:convert, &Convert.options(&1, @telemetry_schema, &2)}]
    ]
  end

  defp url_schema do
    Keyword.merge(ImagePipe.Security.options_schema(),
      source_encryption_keys: [type: {:list, {:convert, &encryption_key/2}}],
      presets: [type: {:map, :string, :string}]
    )
  end

  defp encryption_key(value, path) do
    with {:ok, key} <- Convert.string(value, path) do
      decoded =
        case key do
          "base64:" <> encoded -> Base.decode64(encoded)
          "hex:" <> encoded -> Base.decode16(encoded, case: :mixed)
          _unprefixed -> :prefix
        end

      case decoded do
        {:ok, key} -> {:ok, key}
        :prefix -> {:error, path, "expected a base64: or hex: prefix"}
        :error -> {:error, path, "cannot decode the key"}
      end
    end
  end

  defp cache(value, path) do
    schema = [
      output: [type: {:convert, &file_system(&1, output_schema(), &2)}],
      input: [type: {:convert, &file_system(&1, store_schema(), &2)}],
      storage_inputs: [type: {:list, {:tuple, [{:in, [:header, :cookie]}, :string]}}]
    ]

    with {:ok, options} <- Convert.options(value, schema, path) do
      {:ok,
       Enum.map(options, fn
         {:output, cache} -> {:cache, cache}
         {:input, cache} -> {:input_cache, cache}
         other -> other
       end)}
    end
  end

  defp file_system(value, schema, path) do
    with {:ok, options} <- Convert.options(value, schema, path), do: {:ok, {FileSystem, options}}
  end

  defp store_schema do
    Store.options_schema()
    |> Keyword.delete(:pool)
    |> Keyword.merge(window_ratio: [type: :float], doorkeeper_fpr: [type: :float])
  end

  defp output_schema, do: store_schema() ++ ImagePipe.Cache.shared_options_schema()

  defp processing_schema do
    ImagePipe.Processing.Config.schema()
    |> Keyword.drop([:sources, :processing_pool])
    |> elixir_only([:clock, :telemetry_prefix])
    |> Keyword.merge(
      source_cache_policy: [type: {:convert, &Sources.cache_policy/2}],
      format_order: [type: {:list, {:in, ImagePipe.Format.modern_formats()}}],
      jpeg_options: [type: encoder(JpegOptions)],
      png_options: [type: encoder(PngOptions)],
      webp_options: [type: encoder(WebpOptions)],
      avif_options: [type: encoder(AvifOptions)]
    )
  end

  defp encoder(module) do
    {:convert,
     fn value, path ->
       with {:ok, options} <- Convert.options(value, module.schema(), path),
            do: {:ok, struct!(module, options)}
     end}
  end

  defp pool_schema, do: Keyword.delete(ImagePipe.ProcessingPool.options_schema(), :name)

  defp http_schema, do: ImagePipe.Plug.Config.options_schema()

  defp elixir_only(schema, keys) do
    Enum.reduce(keys, schema, &Keyword.put(&2, &1, type: :any))
  end

  @doc "Validates converted options with the library and builds the server configuration."
  @spec build!(keyword()) :: t()
  def build!(sections) do
    %__MODULE__{
      server: server!(Keyword.get(sections, :server, [])),
      image_pipe: image_pipe!(sections),
      pool: pool!(Keyword.get(sections, :pool)),
      telemetry: telemetry(Keyword.get(sections, :telemetry, []))
    }
  end

  defp server!(options) do
    options = validate!(options, @server_schema, "server")

    [
      port: Keyword.fetch!(options, :port),
      ip: ip!(Keyword.fetch!(options, :bind)),
      mount_path: mount_path!(Keyword.fetch!(options, :mount_path))
    ]
  end

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

  defp image_pipe!(sections) do
    library!(fn ->
      url = ImagePipe.URL.config(Keyword.get(sections, :url, []))

      shared =
        [url: url] ++
          Keyword.get(sections, :processing, []) ++
          Keyword.get(sections, :cache, []) ++
          sources(Keyword.get(sections, :sources))

      ImagePipe.Plug.init([config: ImagePipe.config(shared)] ++ Keyword.get(sections, :http, []))
    end)
  end

  defp sources(nil), do: []
  defp sources(sources), do: [sources: sources]

  # The library names the setting in its errors and keeps secret values out.
  defp library!(fun) do
    fun.()
  rescue
    error in ArgumentError -> reraise ConfigError, [message: error.message], __STACKTRACE__
  end

  defp pool!(nil), do: nil
  defp pool!(options), do: validate!(options, ImagePipe.ProcessingPool.options_schema(), "pool")

  defp telemetry(options) do
    case Keyword.fetch(options, :log_level) do
      {:ok, level} -> [level: level]
      :error -> nil
    end
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

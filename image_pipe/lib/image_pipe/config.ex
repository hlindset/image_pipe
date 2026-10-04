defmodule ImagePipe.Config do
  @moduledoc """
  Reusable host configuration shared by the Plug and direct execution.

  Construct with `ImagePipe.config/1`. Configuration owns sources, caches,
  processing defaults, storage partitions, presets, and request defaults, and
  takes URL settings (signing, source encryption) as an `ImagePipe.URL.Config`
  value. Inspection excludes its values.
  """
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.API,
      ImagePipe.Cache,
      ImagePipe.Processing,
      ImagePipe.Security,
      ImagePipe.Source,
      ImagePipe.URL
    ],
    exports: []

  alias ImagePipe.API.Presets
  alias ImagePipe.Cache
  alias ImagePipe.Processing.Config, as: ProcessingConfig
  alias ImagePipe.Security
  alias ImagePipe.Source
  alias ImagePipe.URL.Config, as: URLConfig

  @enforce_keys [:options, :raw, :url]
  @derive {Inspect, except: [:options, :raw, :url]}
  defstruct @enforce_keys ++ [instance: nil]

  @type t :: %__MODULE__{
          options: keyword(),
          raw: keyword(),
          url: URLConfig.t(),
          instance: atom() | nil
        }

  @preset_keys [:presets, :request_defaults, :preset_lookup, :max_preset_lookups]

  @url_option_doc [
    url: [
      type: {:struct, URLConfig},
      doc: """
      Signing keys, source encryption keys, and the base URL, from \
      `ImagePipe.URL.config/1`. A mount accepts only URLs signed with these keys. \
      Without it, URLs aren't signed.
      """
    ]
  ]

  @schema NimbleOptions.new!(
            ProcessingConfig.schema() ++
              [
                cache: [
                  type: :any,
                  type_doc: "`{module, keyword}`",
                  doc: """
                  Cache for processed images, such as \
                  `{ImagePipe.Cache.FileSystem, root: "/var/cache/image_pipe/processed"}`. \
                  See [caching processed images](caching-processed-images.md). Off by \
                  default.
                  """
                ],
                input_cache: [
                  type: :any,
                  type_doc: "`{module, keyword}`",
                  doc: """
                  Cache for originals fetched from sources, configured like `:cache`. \
                  See [originals cache](cache.md#originals-cache). Off by default.
                  """
                ],
                storage_inputs: [
                  type: {:list, {:custom, __MODULE__, :validate_storage_input, []}},
                  type_doc: "list of `{:header, name}` or `{:cookie, name}`",
                  default: [],
                  doc: """
                  Request headers and cookies whose values select separate cached \
                  copies, such as `[{:header, "x-tenant"}]`. They aren't sent to the \
                  source and don't change the image.
                  """
                ],
                watermarks: [
                  type:
                    {:map, {:custom, __MODULE__, :validate_watermark_name, []}, :keyword_list},
                  type_doc: "map of `t:atom/0` to `t:keyword/0`",
                  default: %{},
                  doc: """
                  Named watermark images that requests select with `wm=name`, as \
                  `%{logo: [source: "brand/logo.png", opacity: 0.6]}`. Names match \
                  `[a-z0-9_-]+`. `:source` is an image path that a configured source \
                  serves. `:opacity`, above `0` and at most `1`, defaults to `1` and \
                  multiplies the request's `wm-opacity`. See \
                  [watermarks](processing/watermark.md).
                  """
                ],
                request_watermarks: [
                  type: :boolean,
                  default: false,
                  doc: """
                  Let requests overlay any image the configured sources serve, with \
                  `wm-src64` or `wm-enc`, besides the named `:watermarks`.
                  """
                ],
                presets: [
                  type: :any,
                  type_doc: "map of `t:String.t/0` to fragment or `ImagePipe.URL` builder",
                  default: %{},
                  doc: """
                  Named sets of options that URLs select with `preset=name`, as URL \
                  fragments such as `%{"card" => "w=400/h=300/fit=cover"}` or \
                  `ImagePipe.URL` builders. See [defining presets](defining-presets.md).
                  """
                ],
                request_defaults: [
                  type: :any,
                  type_doc: "fragment or `ImagePipe.URL` builder",
                  doc: """
                  Options applied to the first group of every request, before presets \
                  and the request's own options. One group, with no `preset`.
                  """
                ],
                preset_lookup: [
                  type: {:custom, __MODULE__, :validate_preset_lookup, []},
                  type_doc: "`{module, keyword}`",
                  doc: """
                  Looks up preset names that `:presets` doesn't define, per request. \
                  See `ImagePipe.PresetLookup` and \
                  [storing presets in a database](storing-presets-in-a-database.md).
                  """
                ],
                max_preset_lookups: [
                  type: :pos_integer,
                  doc: """
                  Most distinct names one request may look up. Only with \
                  `:preset_lookup`. The default value is `32`.
                  """
                ]
              ]
          )

  @doc false
  # The option list for `ImagePipe.config/1`. `:url` is validated before the
  # schema, so it is documented here.
  def options_docs, do: NimbleOptions.docs(@url_option_doc ++ @schema.schema)

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) do
    {url, remaining} = Keyword.pop_lazy(options, :url, fn -> URLConfig.new!([]) end)
    url = url_config!(url)
    resolved = remaining |> Cache.validate_config!() |> Source.validate_config!()

    case NimbleOptions.validate(resolved, @schema) do
      {:ok, validated} ->
        {preset_options, validated} = Keyword.split(validated, @preset_keys)
        {presets, validate_against} = presets!(preset_options)

        validated =
          validated
          |> Keyword.put_new(:clock, &ProcessingConfig.system_time/0)
          |> Keyword.update!(:watermarks, &watermarks!(&1, validated))

        validate_against =
          Map.put(validate_against, :watermarks, Map.keys(Keyword.fetch!(validated, :watermarks)))

        url = URLConfig.put_validate_against(url, validate_against)
        concealed_watermarks!(presets, url)

        resolved =
          validated
          |> ProcessingConfig.resolve!()
          |> Keyword.merge(url.options)
          |> Keyword.merge(presets)

        %__MODULE__{options: resolved, raw: options, url: url}

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{Exception.message(error)}"
    end
  end

  defp url_config!(%URLConfig{options: options} = url) do
    case Keyword.has_key?(options, :validate_against) do
      true ->
        raise ArgumentError,
              "url must not set validate_against; configure presets and watermarks on ImagePipe.config/1"

      false ->
        url
    end
  end

  defp url_config!(_url),
    do: raise(ArgumentError, "url must be built with ImagePipe.URL.config/1")

  # Compiles static presets and request defaults; returns the resolved options
  # and the builder's view of them for `ImagePipe.url_config/1`.
  defp presets!(options) do
    presets =
      Map.new(Keyword.fetch!(options, :presets), fn {name, value} -> {name, plan(value)} end)

    case Presets.compile(presets, plan(options[:request_defaults])) do
      {:ok, compiled} ->
        lookup = lookup_options!(options)

        {[presets: compiled.presets, request_defaults: compiled.request_defaults] ++ lookup,
         Map.put(compiled, :lookup?, lookup != [])}

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{message}"
    end
  end

  # A static wm-enc can only be decrypted with source encryption keys, so a
  # configuration without them would answer every request using it with a 400.
  defp concealed_watermarks!(presets, url) do
    if not Security.source_encryption?(url.options) do
      defaults = Keyword.fetch!(presets, :request_defaults)

      [
        {"request_defaults", defaults}
        | Enum.map(presets[:presets], fn {name, preset} -> {~s(preset "#{name}"), preset} end)
      ]
      |> Enum.find(fn {_owner, preset} -> concealed_watermark?(preset) end)
      |> case do
        nil ->
          :ok

        {owner, _preset} ->
          raise ArgumentError,
                "invalid ImagePipe configuration: #{owner} uses wm-enc, which needs source_encryption_keys"
      end
    end
  end

  defp concealed_watermark?(%{groups: groups}),
    do: Enum.any?(groups, fn {_index, group} -> Map.has_key?(group, :watermark_token) end)

  defp concealed_watermark?(nil), do: false

  defp lookup_options!(options) do
    case {options[:preset_lookup], options[:max_preset_lookups]} do
      {nil, nil} ->
        []

      {nil, _max} ->
        raise ArgumentError,
              "invalid ImagePipe configuration: max_preset_lookups requires preset_lookup"

      {lookup, max} ->
        [preset_lookup: lookup, max_preset_lookups: max || 32]
    end
  end

  defp plan(%ImagePipe.URL{plan: plan}), do: {:plan, plan}
  defp plan(value), do: value

  @doc false
  def validate_preset_lookup({module, options}) when is_atom(module) and is_list(options) do
    with {:module, _module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :validate_options, 1),
         true <- function_exported?(module, :fetch, 2) do
      case module.validate_options(options) do
        {:ok, options} when is_list(options) ->
          {:ok, {module, options}}

        {:error, reason} ->
          {:error, "preset_lookup options are invalid: #{inspect(reason)}"}

        _invalid ->
          {:error,
           "#{inspect(module)}.validate_options/1 must return {:ok, keyword} or {:error, reason}"}
      end
    else
      _missing -> {:error, "#{inspect(module)} does not implement ImagePipe.PresetLookup"}
    end
  end

  def validate_preset_lookup(_lookup),
    do: {:error, "expected a {module, options} tuple implementing ImagePipe.PresetLookup"}

  @doc false
  # Only a supervised instance starts cache processes, so a configuration
  # used without one must not need them.
  @spec reject_unsupervised_processes!(t()) :: t()
  def reject_unsupervised_processes!(%__MODULE__{instance: nil} = config) do
    case Cache.child_specs(config.options) do
      [] ->
        config

      [_ | _] ->
        raise ArgumentError,
              "a cache that needs processes, such as a bounded " <>
                "ImagePipe.Cache.FileSystem, must be used through an ImagePipe instance " <>
                "started with {ImagePipe, name: ..., ...}"
    end
  end

  def reject_unsupervised_processes!(%__MODULE__{} = config), do: config

  @doc false
  # Supervised instances store their configuration here, keyed by name, so
  # mounts can look it up per request.
  @spec publish(atom(), t(), %{atom() => t()}) :: :ok
  def publish(name, config, urls), do: :persistent_term.put({__MODULE__, name}, {config, urls})

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(name) do
    _erased? = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc false
  @spec fetch_instance!(atom(), atom() | nil) :: t()
  def fetch_instance!(name, url) do
    case {:persistent_term.get({__MODULE__, name}, nil), url} do
      {nil, _url} ->
        raise ArgumentError, "ImagePipe instance #{inspect(name)} is not running"

      {{config, _urls}, nil} ->
        config

      {{_config, urls}, url} ->
        case Map.fetch(urls, url) do
          {:ok, config} ->
            config

          :error ->
            raise ArgumentError,
                  "ImagePipe instance #{inspect(name)} has no url named #{inspect(url)}"
        end
    end
  end

  @doc false
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = config, []), do: config

  # The result keeps the instance only while the instance runs every cache
  # process it needs.
  def override(%__MODULE__{} = config, options) do
    overridden = new!(Keyword.merge(config.raw, options))
    running = Cache.child_specs(config.options)

    if config.instance != nil and
         Enum.all?(Cache.child_specs(overridden.options), &(&1 in running)),
       do: %{overridden | instance: config.instance},
       else: overridden
  end

  @watermark_schema NimbleOptions.new!(
                      source: [type: :string, required: true],
                      opacity: [type: {:custom, __MODULE__, :validate_opacity, []}, default: 1.0]
                    )

  @doc false
  # `unset` is the URL value that clears a watermark.
  def validate_watermark_name(:unset),
    do: {:error, "watermark name unset is reserved"}

  def validate_watermark_name(name) when is_atom(name) and not is_nil(name) do
    case Regex.match?(~r/\A[a-z0-9_-]+\z/, Atom.to_string(name)) do
      true -> {:ok, name}
      false -> {:error, "expected watermark names matching [a-z0-9_-]+, got: #{inspect(name)}"}
    end
  end

  def validate_watermark_name(name),
    do: {:error, "expected watermark names as atoms, got: #{inspect(name)}"}

  @doc false
  def validate_opacity(value) when is_number(value) and value > 0 and value <= 1,
    do: {:ok, value * 1.0}

  def validate_opacity(value),
    do: {:error, "expected a number greater than 0 and at most 1, got: #{inspect(value)}"}

  # Requests name assets by string; each entry's source must reach a mount.
  defp watermarks!(watermarks, options) do
    Map.new(watermarks, fn {name, entry} ->
      entry =
        case NimbleOptions.validate(entry, @watermark_schema) do
          {:ok, entry} -> entry
          {:error, error} -> raise_watermark!(name, Exception.message(error))
        end

      case Source.translate_configured(Keyword.fetch!(entry, :source), options) do
        {:ok, source} ->
          {Atom.to_string(name), %{source: source, opacity: Keyword.fetch!(entry, :opacity)}}

        {:error, _reason} ->
          raise_watermark!(name, "source does not reach a configured mount")
      end
    end)
  end

  defp raise_watermark!(name, message),
    do: raise(ArgumentError, "invalid ImagePipe configuration: watermark #{name}: #{message}")

  @doc false
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(_value),
    do: {:error, "expected {:header, name} or {:cookie, name} with a non-empty string name"}
end

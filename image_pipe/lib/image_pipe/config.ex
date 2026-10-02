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
      ImagePipe.Source,
      ImagePipe.URL
    ],
    exports: []

  alias ImagePipe.API.Presets
  alias ImagePipe.Cache
  alias ImagePipe.Processing.Config, as: ProcessingConfig
  alias ImagePipe.Source
  alias ImagePipe.URL.Config, as: URLConfig

  @enforce_keys [:options, :raw, :url]
  @derive {Inspect, except: [:options, :raw, :url]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{options: keyword(), raw: keyword(), url: URLConfig.t()}

  @preset_keys [:presets, :request_defaults, :preset_lookup, :max_preset_lookups]

  @schema NimbleOptions.new!(
            ProcessingConfig.schema() ++
              [
                cache: [type: :any],
                input_cache: [type: :any],
                storage_inputs: [
                  type: {:list, {:custom, __MODULE__, :validate_storage_input, []}},
                  default: []
                ],
                watermarks: [
                  type:
                    {:map, {:custom, __MODULE__, :validate_watermark_name, []}, :keyword_list},
                  default: %{}
                ],
                request_watermarks: [type: :boolean, default: false],
                presets: [type: :any, default: %{}],
                request_defaults: [type: :any],
                preset_lookup: [type: {:custom, __MODULE__, :validate_preset_lookup, []}],
                max_preset_lookups: [type: :pos_integer]
              ]
          )

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) do
    {url, remaining} = Keyword.pop_lazy(options, :url, fn -> URLConfig.new!([]) end)
    url = url_config!(url)
    resolved = remaining |> Cache.validate_config!() |> Source.validate_config!()

    case NimbleOptions.validate(resolved, @schema) do
      {:ok, validated} ->
        {preset_options, validated} = Keyword.split(validated, @preset_keys)
        {presets, mount_presets} = presets!(preset_options)
        url = URLConfig.put_mount_presets(url, mount_presets)

        validated =
          validated
          |> Keyword.put_new(:clock, &ProcessingConfig.system_time/0)
          |> Keyword.update!(:watermarks, &watermarks!(&1, validated))

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
    case Keyword.has_key?(options, :mount_presets) do
      true ->
        raise ArgumentError,
              "url must not set mount_presets; configure presets on ImagePipe.config/1"

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
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = config, []), do: config
  def override(%__MODULE__{} = config, options), do: new!(Keyword.merge(config.raw, options))

  @watermark_schema NimbleOptions.new!(
                      source: [type: :string, required: true],
                      opacity: [type: {:custom, __MODULE__, :validate_opacity, []}, default: 1.0]
                    )

  @doc false
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

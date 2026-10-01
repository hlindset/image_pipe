defmodule ImagePipe.Config do
  @moduledoc """
  Reusable host configuration shared by the Plug and direct execution.

  Construct with `ImagePipe.config/1`. Configuration owns sources, caches,
  processing defaults, and storage partitions, and takes URL settings (signing,
  source encryption, presets) as an `ImagePipe.URL.Config` value. Inspection
  excludes its values.
  """
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.Processing, ImagePipe.Source, ImagePipe.URL],
    exports: []

  alias ImagePipe.Cache
  alias ImagePipe.Processing.Config, as: ProcessingConfig
  alias ImagePipe.Source
  alias ImagePipe.URL.Config, as: URLConfig

  @enforce_keys [:options, :raw]
  @derive {Inspect, except: [:options, :raw]}
  defstruct @enforce_keys
  @type t :: %__MODULE__{options: keyword(), raw: keyword()}

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
                request_watermarks: [type: :boolean, default: false]
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
        validated =
          validated
          |> Keyword.put_new(:clock, &ProcessingConfig.system_time/0)
          |> Keyword.update!(:watermarks, &watermarks!(&1, validated))

        resolved =
          validated
          |> ProcessingConfig.resolve!()
          |> Keyword.merge(url.options)

        %__MODULE__{options: resolved, raw: options}

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{Exception.message(error)}"
    end
  end

  defp url_config!(%URLConfig{} = url), do: url

  defp url_config!(_url),
    do: raise(ArgumentError, "url must be built with ImagePipe.URL.config/1")

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

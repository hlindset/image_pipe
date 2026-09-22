defmodule ImagePipe.Config do
  @moduledoc """
  Reusable host configuration shared by the Plug and the Elixir API.

  Construct with `ImagePipe.config/1`. Configuration owns sources, caches,
  processing defaults, storage partitions, URL defaults, and signing/encryption
  settings. Inspection excludes its values.
  """
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.Processing, ImagePipe.Security, ImagePipe.Source],
    exports: []

  alias ImagePipe.Cache
  alias ImagePipe.Config.URL
  alias ImagePipe.Processing.Config, as: ProcessingConfig
  alias ImagePipe.Security
  alias ImagePipe.Source

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
                ]
              ]
          )

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) do
    {security, remaining} = Security.extract!(options)
    {url, remaining} = URL.extract!(remaining)
    resolved = remaining |> Cache.validate_config!() |> Source.validate_config!()

    case NimbleOptions.validate(resolved, @schema) do
      {:ok, validated} ->
        validated = Keyword.put_new(validated, :clock, &ProcessingConfig.system_time/0)

        resolved =
          validated
          |> ProcessingConfig.resolve!()
          |> Keyword.merge(security)
          |> Keyword.merge(url)

        %__MODULE__{options: resolved, raw: options}

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{Exception.message(error)}"
    end
  end

  @doc false
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = config, []), do: config
  def override(%__MODULE__{} = config, options), do: new!(Keyword.merge(config.raw, options))

  @doc false
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(_value),
    do: {:error, "expected {:header, name} or {:cookie, name} with a non-empty string name"}
end

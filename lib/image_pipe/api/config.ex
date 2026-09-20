defmodule ImagePipe.API.Config do
  @moduledoc """
  Validates and resolves the mount configuration.

  Mount-only parsing, cache, and delivery controls extend the shared processing
  configuration used by direct Elixir execution.
  """

  alias ImagePipe.API.OptionSpec
  alias ImagePipe.API.Presets
  alias ImagePipe.API.Security
  alias ImagePipe.Cache
  alias ImagePipe.Processing.Config, as: ProcessingConfig
  alias ImagePipe.Source

  @options_schema NimbleOptions.new!(
                    ProcessingConfig.schema() ++
                      [
                        cache: [type: :any],
                        input_cache: [type: :any],
                        allow_origin: [
                          type: {:custom, __MODULE__, :validate_allow_origin, []}
                        ],
                        allow_debug_headers: [type: :boolean, default: false],
                        presets: [
                          type: {:custom, __MODULE__, :validate_presets, []},
                          default: %{}
                        ],
                        http_cache: [
                          type: :keyword_list,
                          keys: [
                            mode: [type: {:in, [:disabled, :enabled]}, default: :disabled],
                            visibility: [type: {:in, [:auto, :private, :public]}, default: :auto]
                          ]
                        ],
                        storage_inputs: [
                          type: {:list, {:custom, __MODULE__, :validate_storage_input, []}},
                          default: []
                        ]
                      ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {security, opts} = Security.extract!(opts)

    opts
    |> Cache.validate_config!()
    |> Source.validate_config!()
    |> validate_known_opts!()
    |> ProcessingConfig.resolve!()
    |> Keyword.merge(security)
  end

  @doc false
  def validate_presets(value) when is_map(value) do
    if Enum.all?(value, fn {name, fragment} ->
         is_binary(name) and is_binary(fragment) and
           OptionSpec.parse_preset_names(name) == {:ok, [name]}
       end) do
      Presets.validate_config(value)
    else
      {:error, "expected a map of preset name to option-fragment string, got: #{inspect(value)}"}
    end
  end

  def validate_presets(value),
    do:
      {:error, "expected a map of preset name to option-fragment string, got: #{inspect(value)}"}

  @doc false
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(value) do
    {:error,
     "expected {:header, name} or {:cookie, name} with a non-empty string name, got: #{inspect(value)}"}
  end

  @doc false
  def validate_allow_origin(value) when is_binary(value) and value != "" do
    if String.match?(value, ~r/[[:cntrl:]]/),
      do: {:error, "must not contain control characters"},
      else: {:ok, value}
  end

  def validate_allow_origin(""),
    do: {:error, "expected a non-empty string (omit allow_origin to disable CORS)"}

  def validate_allow_origin(_value), do: {:error, "expected a string"}

  defp validate_known_opts!(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.put_new(validated_opts, :clock, fn -> System.os_time(:second) end)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.API options: #{Exception.message(error)}"
    end
  end
end

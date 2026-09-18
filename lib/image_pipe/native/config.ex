defmodule ImagePipe.Native.Config do
  @moduledoc false

  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Native.OptionSpec
  alias ImagePipe.Native.Presets

  @validated_option_keys [
    :keys,
    :presets,
    :http_cache,
    :storage_inputs
  ]
  @options_schema NimbleOptions.new!(
                    keys: [
                      type: {:list, {:custom, __MODULE__, :validate_hex_key, []}},
                      default: []
                    ],
                    presets: [
                      type: {:custom, __MODULE__, :validate_presets, []},
                      default: %{}
                    ],
                    http_cache: [
                      type: :keyword_list,
                      keys: [mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]]
                    ],
                    storage_inputs: [
                      type: {:list, {:custom, SharedConfig, :validate_storage_input, []}},
                      default: []
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared_opts, native_opts} = Keyword.split(opts, SharedConfig.keys())

    native_opts =
      native_opts
      |> reject_unknown_opts!()
      |> validate_known_opts!()

    Keyword.merge(native_opts, SharedConfig.validate_runtime!(shared_opts))
  end

  @doc false
  def validate_hex_key(value) when is_binary(value) and value != "" do
    case Base.decode16(value, case: :mixed) do
      {:ok, _binary} -> {:ok, value}
      :error -> {:error, "expected a hex-encoded string, got: #{inspect(value)}"}
    end
  end

  def validate_hex_key(value),
    do: {:error, "expected a hex-encoded string, got: #{inspect(value)}"}

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

  defp reject_unknown_opts!(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @validated_option_keys)) do
      nil ->
        opts

      key ->
        raise ArgumentError, "unknown ImagePipe.Native option #{inspect(key)}"
    end
  end

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Native options: #{Exception.message(error)}"
    end
  end
end

defmodule ImagePipe.Dialect.Native.Config do
  @moduledoc false

  alias ImagePipe.Dialect.Native.Presets
  alias ImagePipe.Dialect.SharedConfig

  @validated_option_keys [
    :keys,
    :presets,
    :on_inert_option,
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
                    on_inert_option: [
                      type: {:in, [:reject, :ignore]},
                      default: :reject
                    ],
                    storage_inputs: [
                      type: {:list, {:custom, SharedConfig, :validate_storage_input, []}},
                      default: []
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared_opts, dialect_opts} = Keyword.split(opts, SharedConfig.keys())

    dialect_opts =
      dialect_opts
      |> reject_unknown_opts!()
      |> validate_known_opts!()
      |> reject_unimplemented_on_inert_option!()

    Keyword.merge(dialect_opts, SharedConfig.validate_runtime!(shared_opts))
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
    if Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end) do
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
        raise ArgumentError, "unknown ImagePipe.Dialect.Native option #{inspect(key)}"
    end
  end

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.Native options: #{Exception.message(error)}"
    end
  end

  defp reject_unimplemented_on_inert_option!(opts) do
    case Keyword.fetch(opts, :on_inert_option) do
      {:ok, :ignore} ->
        raise ArgumentError,
              "ImagePipe.Dialect.Native on_inert_option: :ignore is not yet implemented"

      _other ->
        opts
    end
  end
end

defmodule ImagePipe.Native.Config do
  @moduledoc false

  alias ImagePipe.Config, as: CoreConfig
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Native.OptionSpec
  alias ImagePipe.Native.Presets

  @supported_neutral_keys [
    :strip_metadata,
    :keep_copyright,
    :strip_color_profile,
    :preserve_hdr,
    :quality,
    :format_quality,
    :autoquality_method,
    :autoquality_target,
    :autoquality_min_quality,
    :autoquality_max_quality,
    :autoquality_allowed_error,
    :autoquality_format_min_quality,
    :autoquality_format_max_quality,
    :autoquality_max_resolution,
    :autoquality_max_iterations,
    :jpeg_options,
    :png_options,
    :webp_options,
    :avif_options,
    :jxl_options
  ]

  @validated_option_keys [
    :keys,
    :presets,
    :http_cache,
    :storage_inputs,
    :detector,
    :detector_required
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
                    ],
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      default: :default
                    ],
                    detector_required: [
                      type: :boolean,
                      default: false
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared_opts, rest} = Keyword.split(opts, SharedConfig.keys())
    {neutral_opts, native_opts} = Keyword.split(rest, CoreConfig.keys())

    native_opts =
      native_opts
      |> reject_unknown_opts!()
      |> validate_known_opts!()

    neutral_opts =
      neutral_opts
      |> CoreConfig.reject_unsupported!(@supported_neutral_keys, "native")
      |> CoreConfig.resolve!()

    shared_opts
    |> SharedConfig.validate_runtime!()
    |> Keyword.merge(neutral_opts)
    |> Keyword.merge(native_opts)
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

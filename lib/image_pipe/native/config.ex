defmodule ImagePipe.Native.Config do
  @moduledoc false

  alias ImagePipe.Config, as: CoreConfig
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Native.OptionSpec
  alias ImagePipe.Native.Presets
  alias ImagePipe.Native.SourceEncryption

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
    :source_schemes,
    :http_cache,
    :storage_inputs,
    :detector,
    :detector_required
  ]
  @options_schema NimbleOptions.new!(
                    presets: [
                      type: {:custom, __MODULE__, :validate_presets, []},
                      default: %{}
                    ],
                    source_schemes: [
                      type: {:custom, __MODULE__, :validate_source_schemes, []},
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
    {source_encryption_keys, native_opts} = Keyword.pop(native_opts, :source_encryption_keys, [])
    source_encryption = validate_source_encryption_keys!(source_encryption_keys)
    {signing_keys, native_opts} = Keyword.pop(native_opts, :keys, [])
    signing_keys = validate_signing_keys!(signing_keys)

    native_opts =
      native_opts
      |> reject_unknown_opts!()
      |> validate_known_opts!()
      |> Keyword.put(:keys, signing_keys)
      |> validate_source_encryption_config!(source_encryption)
      |> Keyword.put(:source_encryption, source_encryption)

    neutral_opts =
      neutral_opts
      |> CoreConfig.reject_unsupported!(@supported_neutral_keys, "native")
      |> CoreConfig.resolve!()

    shared_opts
    |> SharedConfig.validate_runtime!()
    |> Keyword.merge(neutral_opts)
    |> Keyword.merge(native_opts)
  end

  defp validate_hex_key(value) when is_binary(value) and value != "" do
    case Base.decode16(value, case: :mixed) do
      {:ok, _binary} -> {:ok, value}
      :error -> {:error, "expected a hex-encoded string"}
    end
  end

  defp validate_hex_key(_value),
    do: {:error, "expected a hex-encoded string"}

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
  def validate_source_schemes(%{} = schemes) do
    if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
      {:ok, schemes}
    else
      {:error, "expected a map from canonical custom scheme names to {module, keyword_options}"}
    end
  end

  def validate_source_schemes(_schemes) do
    {:error, "expected a map from canonical custom scheme names to {module, keyword_options}"}
  end

  defp valid_source_scheme_entry?({scheme, {translator, translator_opts}}) do
    valid_custom_scheme?(scheme) and valid_source_scheme_translator?(translator) and
      Keyword.keyword?(translator_opts)
  end

  defp valid_source_scheme_entry?(_entry), do: false

  defp valid_custom_scheme?(scheme) when is_binary(scheme) do
    scheme not in ["http", "https", "s3"] and
      String.match?(scheme, ~r/^[a-z][a-z0-9+.\-]*$/)
  end

  defp valid_custom_scheme?(_scheme), do: false

  defp valid_source_scheme_translator?(translator) when is_atom(translator) do
    Code.ensure_loaded?(translator) and function_exported?(translator, :translate, 2)
  end

  defp valid_source_scheme_translator?(_translator), do: false

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

  defp validate_source_encryption_keys!(keys) do
    case SourceEncryption.new(keys) do
      {:ok, source_encryption} ->
        source_encryption

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe.Native source_encryption_keys: #{message}"
    end
  end

  defp validate_signing_keys!(keys) when is_list(keys) do
    if Enum.all?(keys, &match?({:ok, _key}, validate_hex_key(&1))) do
      keys
    else
      raise ArgumentError, "invalid ImagePipe.Native signing keys"
    end
  end

  defp validate_signing_keys!(_keys) do
    raise ArgumentError, "invalid ImagePipe.Native signing keys"
  end

  defp validate_source_encryption_config!(opts, source_encryption) do
    signing_keys = Keyword.fetch!(opts, :keys)

    cond do
      SourceEncryption.disabled?(source_encryption) ->
        opts

      signing_keys == [] ->
        raise ArgumentError, "source encryption requires signing keys"

      shared_key_material?(signing_keys, source_encryption) ->
        raise ArgumentError, "signing and source encryption keys must be independent"

      true ->
        opts
    end
  end

  defp shared_key_material?(signing_keys, source_encryption) do
    Enum.any?(signing_keys, fn signing_key ->
      {:ok, decoded} = Base.decode16(signing_key, case: :mixed)
      SourceEncryption.key?(source_encryption, decoded)
    end)
  end
end

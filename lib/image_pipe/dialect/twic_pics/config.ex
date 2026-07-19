defmodule ImagePipe.Dialect.TwicPics.Config do
  @moduledoc false

  alias ImagePipe.Config, as: NeutralConfig
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan.Output.QualitySearch

  @dialect_keys [
    :storage_inputs,
    :detector,
    :detector_required,
    :allow_debug_headers
  ]

  # Hosted TwicPics `output=auto` selects WebP for browsers that accept it and
  # never auto-selects AVIF or JPEG XL (verified against imagepipe.twic.pics: a
  # Chrome Accept returns WebP; `Accept: image/avif` alone falls back to the
  # source format). The dialect matches that by defaulting AVIF/JXL auto
  # negotiation off — a dialect-local default only, not a change to the neutral
  # output policy or the other dialects. Explicit `output=avif` still bypasses
  # negotiation, and a host may re-enable auto AVIF/JXL by passing the flag.
  @auto_format_defaults [auto_avif: false, auto_jpeg_xl: false]

  @dialect_schema NimbleOptions.new!(
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
                    ],
                    allow_debug_headers: [
                      type: :boolean,
                      default: false
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {neutral, rest} = Keyword.split(rest, NeutralConfig.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    reject_unknown!(unknown)

    resolved =
      @auto_format_defaults
      |> Keyword.merge(shared)
      |> SharedConfig.validate_runtime!()
      |> Keyword.merge(NeutralConfig.resolve!(neutral, []))
      |> Keyword.merge(validate_dialect!(dialect))

    validate_autoquality!(resolved)
    resolved
  end

  defp reject_unknown!([]), do: :ok

  defp reject_unknown!(unknown) do
    raise ArgumentError,
          "unknown ImagePipe.Dialect.TwicPics option(s): #{inspect(Keyword.keys(unknown))}"
  end

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.TwicPics options: #{Exception.message(error)}"
    end
  end

  defp validate_autoquality!(config) do
    case QualitySearch.from_config(config) do
      {:ok, _quality_search} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.TwicPics autoquality config: #{inspect(reason)}"
    end
  end
end

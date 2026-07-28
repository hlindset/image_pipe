defmodule ImagePipe.Dialect.IIIF.Config do
  @moduledoc false

  alias ImagePipe.Config, as: NeutralConfig
  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Dialect.IIIF.Resolver
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan.Output.QualitySearch

  @dialect_keys [:resolver, :formats, :qualities, :tile_size, :max_width, :max_height, :max_area]

  # The full neutral surface is honored; the reject seam is a no-op today.
  @supported_neutral :all

  @dialect_schema NimbleOptions.new!(
                    resolver: [
                      type: {:custom, Resolver, :validate, []},
                      required: true
                    ],
                    formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
                    qualities: [
                      type: {:list, :atom},
                      default: [:default, :color, :gray, :bitonal]
                    ],
                    tile_size: [type: :pos_integer, default: 512],
                    max_width: [type: :pos_integer],
                    max_height: [type: :pos_integer],
                    max_area: [type: :pos_integer]
                  )

  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {base, rest} = Keyword.split(rest, Declarative.config_keys())
    {neutral, rest} = Keyword.split(rest, NeutralConfig.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    reject_unknown!(unknown)
    validate_max_bounds!(dialect)

    resolved =
      shared
      |> SharedConfig.validate_runtime!()
      |> Keyword.merge(Declarative.validate_config!(base))
      |> Keyword.merge(validate_neutral!(neutral))
      |> Keyword.merge(validate_dialect!(dialect))

    validate_autoquality!(resolved)
    resolved
  end

  defp reject_unknown!([]), do: :ok

  defp reject_unknown!(unknown) do
    raise ArgumentError,
          "unknown ImagePipe.Dialect.IIIF option(s): #{inspect(Keyword.keys(unknown))}"
  end

  defp validate_neutral!(neutral) do
    neutral
    |> NeutralConfig.reject_unsupported!(@supported_neutral, "IIIF")
    |> NeutralConfig.resolve!([])
  end

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePipe.Dialect.IIIF options: #{Exception.message(error)}"
    end
  end

  # IIIF Image API 3.0 §5.1: maxWidth must be specified if maxHeight is.
  # Checked on the RAW keyword — neither bound is defaulted, so presence is the
  # discriminator and it must be read before the schema merge.
  defp validate_max_bounds!(dialect) do
    if Keyword.has_key?(dialect, :max_height) and not Keyword.has_key?(dialect, :max_width) do
      raise ArgumentError,
            "ImagePipe.Dialect.IIIF max_height requires max_width (IIIF Image API 3.0 §5.1)"
    end

    :ok
  end

  # Config-only dialect: the autoquality search is fully determined here, so a
  # bad method/target combination surfaces at boot, not per request.
  defp validate_autoquality!(config) do
    case QualitySearch.from_config(config) do
      {:ok, _quality_search} ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.IIIF autoquality config: #{inspect(reason)}"
    end
  end
end

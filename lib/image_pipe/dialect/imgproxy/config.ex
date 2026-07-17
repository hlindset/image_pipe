defmodule ImagePipe.Dialect.Imgproxy.Config do
  @moduledoc """
  The dialect's `Plug.init/1` validator — a three-way split of a FLAT
  keyword list (unlike the framework's `:imgproxy`-nested shape) into:

    * shared runtime keys (`ImagePipe.Dialect.SharedConfig`) — source
      fetching, caching, request-safety limits;
    * product-neutral plan/output tunables (`ImagePipe.Config`) — quality,
      format_quality, autoquality, encoder options, …;
    * this dialect's own keys — signature, source URL encryption, source
      schemes, presets, configured storage-vary inputs, and the request
      clock.

  Any key outside all three sets raises. `imgproxy_overlay/0` is empty
  ("imgproxy parity == neutral defaults") — the sparse-parity-override seam
  a future byte-parity lever (e.g. `jxl_options`) would use.
  """

  alias ImagePipe.Dialect.Imgproxy.Presets
  alias ImagePipe.Dialect.Imgproxy.Signature
  alias ImagePipe.Dialect.Imgproxy.SourceEncryption
  alias ImagePipe.Dialect.SharedConfig

  @dialect_keys [
    :signature,
    :source_url_encryption_key,
    :base64_url_includes_filename,
    :source_schemes,
    :presets,
    :storage_inputs,
    :detector,
    :detector_required,
    :clock
  ]

  @dialect_schema NimbleOptions.new!(
                    signature: [type: :keyword_list, required: false],
                    source_url_encryption_key: [
                      type: {:custom, SourceEncryption, :validate_key, []},
                      required: false
                    ],
                    base64_url_includes_filename: [
                      type: :boolean,
                      default: false
                    ],
                    source_schemes: [
                      type: {:custom, __MODULE__, :validate_source_schemes, []},
                      default: %{}
                    ],
                    presets: [
                      type: {:custom, Presets, :validate_config, []},
                      default: %{}
                    ],
                    storage_inputs: [
                      type: {:list, {:custom, SharedConfig, :validate_storage_input, []}},
                      default: []
                    ],
                    # The host-configured content detector, mirroring
                    # `ImagePipe.Request.Options`: `:default` resolves to the
                    # bundled composite, `nil` disables detection, or a module
                    # names a custom detector. Seeded onto the transform state so
                    # object-guided crops reach it, and consulted by the
                    # strict-mode capability gate below.
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      default: :default
                    ],
                    # The strict-mode capability gate: under `detector_required:
                    # true`, an object-detection request whose configured detector
                    # is unavailable rejects before source fetch or cache access
                    # rather than silently degrading to attention cropping. The
                    # default matches the framework's (`ImagePipe.Request.Options`).
                    detector_required: [
                      type: :boolean,
                      default: false
                    ],
                    clock: [
                      type: {:custom, __MODULE__, :validate_clock, []},
                      default: &DateTime.utc_now/0
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    # ImagePipe.Config.keys/0 is an established public interface — config.ex:97,
    # already consumed exactly this way by `ImagePipe.Parser.IIIF` and
    # `ImagePipe.Parser.TwicPics`. No new core widening here.
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {neutral, rest} = Keyword.split(rest, ImagePipe.Config.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    unless unknown == [] do
      raise ArgumentError,
            "unknown ImagePipe.Dialect.Imgproxy option(s): #{inspect(Keyword.keys(unknown))}"
    end

    SharedConfig.validate_runtime!(shared)
    |> Keyword.merge(ImagePipe.Config.resolve!(neutral, imgproxy_overlay()))
    |> Keyword.merge(validate_dialect!(dialect))
  end

  # Sparse parity overrides applied on top of the neutral defaults. EMPTY today
  # ("imgproxy parity == neutral defaults") — the seam a future byte-parity
  # lever (e.g. `jxl_options`) would use.
  defp imgproxy_overlay, do: []

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated
        |> Keyword.update(:signature, Signature.disabled(), &Signature.normalize_config!/1)
        |> normalize_source_encryption()

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.Imgproxy options: #{Exception.message(error)}"
    end
  end

  defp normalize_source_encryption(validated) do
    {source_url_encryption, validated} = Keyword.pop(validated, :source_url_encryption_key)

    Keyword.put(validated, :source_url_encryption, source_url_encryption)
  end

  @doc false
  def validate_source_schemes(%{} = schemes) do
    if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
      {:ok, schemes}
    else
      {:error, "expected a map from binary scheme names to {module, keyword_options}"}
    end
  end

  def validate_source_schemes(_schemes),
    do: {:error, "expected a map from binary scheme names to {module, keyword_options}"}

  defp valid_source_scheme_entry?({scheme, {translator, translator_opts}}) do
    is_binary(scheme) and valid_source_scheme_translator?(translator) and
      Keyword.keyword?(translator_opts)
  end

  defp valid_source_scheme_entry?(_entry), do: false

  defp valid_source_scheme_translator?(translator) when is_atom(translator) do
    Code.ensure_loaded?(translator) and function_exported?(translator, :translate, 2)
  end

  defp valid_source_scheme_translator?(_translator), do: false

  @doc false
  def validate_clock(clock) when is_function(clock, 0), do: {:ok, clock}

  def validate_clock(_clock),
    do: {:error, "expected zero-arity function"}
end

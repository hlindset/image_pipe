defmodule ImagePipe.Request.Options do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @default_max_body_bytes 10_000_000
  @default_max_input_pixels 40_000_000
  @default_max_result_width 8_192
  @default_max_result_height 8_192
  @default_max_result_pixels 40_000_000

  @validated_option_keys [
    :parser,
    :clock,
    :telemetry_prefix,
    :http_cache,
    :detector,
    :detector_required,
    :max_body_bytes,
    :max_input_pixels,
    :max_result_width,
    :max_result_height,
    :max_result_pixels,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl
  ]
  @stale_origin_option_keys [
    :root_url,
    :origin_req_options,
    :origin_receive_timeout,
    :origin_max_redirects
  ]
  @source_runtime_option_keys [
    :max_body_bytes,
    :receive_timeout,
    :connect_timeout,
    :pool_timeout,
    :request_id,
    :telemetry_prefix
  ]
  # Real top-level options read directly by downstream consumers (negotiation,
  # cache key, capabilities) with their own defaults rather than this schema.
  # Listed so a near-miss typo of them is caught too.
  @passthrough_option_keys [:auto_avif, :auto_webp, :auto_jpeg_xl, :output_capabilities]

  # Names a typo is matched against. Not a closed allowlist: the option surface
  # is deliberately open (parser config namespaces, DI/runtime seams, detector
  # extension keys), so we only flag an unknown key that is a close edit-distance
  # match to one of these — closing the silent-typo footgun (e.g. a misspelled
  # safety limit) without rejecting legitimately-unknown extension keys.
  @known_option_names Enum.uniq(
                        @validated_option_keys ++
                          @source_runtime_option_keys ++
                          @passthrough_option_keys ++
                          [:cache, :sources]
                      )
  # A name is a likely typo of a known option when it is a near edit-distance
  # match and a similar length (guards against false positives on keys that
  # merely share a long prefix, e.g. `max_result_width`/`max_result_height`).
  @typo_jaro_threshold 0.9
  @typo_max_length_diff 2
  @options_schema NimbleOptions.new!(
                    parser: [type: :atom, required: true],
                    clock: [type: {:custom, __MODULE__, :validate_clock, []}],
                    max_body_bytes: [
                      type: :pos_integer,
                      default: @default_max_body_bytes
                    ],
                    max_input_pixels: [
                      type: :pos_integer,
                      default: @default_max_input_pixels
                    ],
                    max_result_width: [
                      type: :pos_integer,
                      default: @default_max_result_width
                    ],
                    max_result_height: [
                      type: :pos_integer,
                      default: @default_max_result_height
                    ],
                    max_result_pixels: [
                      type: :pos_integer,
                      default: @default_max_result_pixels
                    ],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      default: Telemetry.default_prefix()
                    ],
                    http_cache: [
                      type: :keyword_list,
                      default: [mode: :disabled],
                      keys: [
                        mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]
                      ]
                    ],
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      default: :default
                    ],
                    detector_required: [
                      type: :boolean,
                      default: false
                    ],
                    auto_avif: [
                      type: :boolean,
                      default: true
                    ],
                    auto_webp: [
                      type: :boolean,
                      default: true
                    ],
                    auto_jpeg_xl: [
                      type: :boolean,
                      default: true
                    ]
                  )

  def validate!(opts) do
    opts
    |> Cache.validate_config!()
    |> Source.validate_config!()
    |> reject_stale_origin_opts!()
    |> reject_typo_opts!()
    |> validate_known_opts!()
  end

  def source_runtime_opts(opts) when is_list(opts) do
    Keyword.take(opts, @source_runtime_option_keys)
  end

  @doc false
  def validate_clock(clock) when is_function(clock, 0), do: {:ok, clock}

  def validate_clock(_clock),
    do: {:error, "expected zero-arity function"}

  @doc false
  def validate_telemetry_prefix([prefix | _rest] = telemetry_prefix) when is_atom(prefix) do
    if Enum.all?(telemetry_prefix, &is_atom/1) do
      {:ok, telemetry_prefix}
    else
      {:error, "expected a non-empty list of atoms"}
    end
  end

  def validate_telemetry_prefix(_telemetry_prefix),
    do: {:error, "expected a non-empty list of atoms"}

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePipe options: #{Exception.message(error)}"
    end
  end

  defp reject_typo_opts!(opts) do
    opts
    |> Keyword.keys()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @known_option_names))
    |> Enum.each(fn key ->
      case nearest_known_option(key) do
        nil ->
          :ok

        suggestion ->
          raise ArgumentError,
                "unknown ImagePipe option #{inspect(key)} — did you mean #{inspect(suggestion)}?"
      end
    end)

    opts
  end

  defp nearest_known_option(key) do
    key_string = Atom.to_string(key)

    @known_option_names
    |> Enum.map(fn known -> {known, String.jaro_distance(Atom.to_string(known), key_string)} end)
    |> Enum.filter(fn {known, distance} ->
      distance >= @typo_jaro_threshold and
        abs(String.length(Atom.to_string(known)) - String.length(key_string)) <=
          @typo_max_length_diff
    end)
    |> Enum.max_by(fn {_known, distance} -> distance end, fn -> nil end)
    |> case do
      nil -> nil
      {known, _distance} -> known
    end
  end

  defp reject_stale_origin_opts!(opts) do
    case Enum.find(@stale_origin_option_keys, &Keyword.has_key?(opts, &1)) do
      nil ->
        opts

      key ->
        raise ArgumentError, "invalid ImagePipe options: stale origin option #{inspect(key)}"
    end
  end
end

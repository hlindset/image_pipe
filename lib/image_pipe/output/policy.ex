defmodule ImagePipe.Output.Policy do
  @moduledoc false

  alias ImagePipe.Error
  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output
  alias ImagePipe.Telemetry

  @enforce_keys [
    :mode,
    :modern_candidates,
    :headers,
    :quality,
    :format_qualities,
    :strip_metadata,
    :keep_copyright,
    :color_profile
  ]
  defstruct @enforce_keys ++
              [
                flatten_background: Color.white(),
                default_quality: :default,
                quality_search: :none,
                quality_search_max_iterations: 6,
                max_bytes: nil,
                quality_search_offsets: Output.default_quality_search_offsets(),
                encoder_options: %{},
                hdr: :tone_map
              ]

  @passthrough_source_formats [:jpeg, :png]

  # Lossless output formats do not take the configured numeric default quality
  # (a numeric Q would trigger PNG quantization). An explicit URL q/fq still
  # applies; only the implicit global default is gated.
  @lossless_default_formats [:png]

  @type format() :: Format.output_format()
  @type source_format() :: Format.source_format()
  @type quality() :: Output.quality()
  @type mode() :: :source | {:explicit, format()}

  @type t() :: %__MODULE__{
          mode: mode(),
          modern_candidates: [format()],
          headers: [{String.t(), String.t()}],
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          default_quality: quality(),
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: Output.color_profile(),
          flatten_background: Color.t(),
          quality_search:
            :none
            | Output.QualitySearch.Size.t()
            | Output.QualitySearch.Ssimulacra2.t()
            | Output.QualitySearch.Butteraugli.t(),
          quality_search_max_iterations: pos_integer(),
          max_bytes: nil | pos_integer(),
          quality_search_offsets: Output.quality_search_offsets(),
          encoder_options: %{optional(format()) => struct()},
          hdr: Output.hdr()
        }

  @type identity_selection() ::
          {:explicit, format()} | {:auto_head, format()} | :source_negotiated

  @doc """
  The pure pre-source-fetch format selection: explicit format, the negotiated
  auto-candidate head, or a deferral to source-format resolution. Public and
  core-owned so request identity material can read the same decision that
  `resolve/2` later encodes, without re-deriving negotiation.
  """
  @spec identity_selection(t()) :: identity_selection()
  def identity_selection(%__MODULE__{mode: {:explicit, format}}), do: {:explicit, format}

  def identity_selection(%__MODULE__{mode: :source, modern_candidates: [format | _rest]}),
    do: {:auto_head, format}

  def identity_selection(%__MODULE__{mode: :source, modern_candidates: []}),
    do: :source_negotiated

  @doc """
  Canonical keyword of the effective, config-resolved byte-affecting policy:
  quality, format defaults/overrides, quality search (canonicalized to a
  digestible shape), byte/metadata/color/HDR/background/encoder knobs.
  Deliberately excludes `mode`/`modern_candidates`/`headers` — negotiation
  enters identity only via `identity_selection/1`'s outcome, never the raw
  Accept header.
  """
  @spec identity_material(t()) :: keyword()
  def identity_material(%__MODULE__{} = policy) do
    [
      quality: policy.quality,
      default_quality: policy.default_quality,
      format_qualities: policy.format_qualities,
      quality_search: quality_search_identity(policy.quality_search),
      quality_search_max_iterations: search_iteration_identity(policy),
      quality_search_offsets: policy.quality_search_offsets,
      max_bytes: policy.max_bytes,
      strip_metadata: policy.strip_metadata,
      keep_copyright: policy.keep_copyright,
      color_profile: policy.color_profile,
      hdr: policy.hdr,
      flatten_background: Color.key_data(policy.flatten_background),
      encoder_options: encoder_options_identity(policy.encoder_options)
    ]
  end

  @spec resolve(t(), source_format() | nil) ::
          {:ok, Resolved.t()}
          | {:error, :source_format_required}
          | {:needs_final_image_alpha, :source}
  def resolve(%__MODULE__{} = policy, source_format) do
    case identity_selection(policy) do
      {:explicit, format} ->
        {:ok, resolved(policy, format)}

      {:auto_head, format} ->
        {:ok, resolved(policy, format)}

      :source_negotiated ->
        case resolve_source_format(policy, source_format) do
          {:selected, format, _reason} -> {:ok, resolved(policy, format)}
          {:needs_final_image_alpha, _reason} = pending -> pending
          {:error, _reason} = error -> error
        end
    end
  end

  @spec negotiate(t(), source_format(), Vix.Vips.Image.t(), keyword()) ::
          {:ok, Resolved.t()} | {:error, term()}
  def negotiate(%__MODULE__{} = policy, source_format, image, telemetry_opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(telemetry_opts),
      [:output, :negotiate],
      %{output_mode: output_mode(policy)},
      fn ->
        result =
          case resolve(policy, source_format) do
            {:needs_final_image_alpha, :source} ->
              {:ok, resolve_final_image_alpha(policy, Image.has_alpha?(image))}

            result ->
              result
          end

        {result, stop_metadata(result)}
      end
    )
  end

  @doc """
  Whether the HDR working space should be kept (`Policy.hdr == :preserve`
  and the output format carries HDR). Computed pre-transform so it can seed the
  input-color-management stage. In the one branch where the format is only known
  after the transform (`:needs_final_image_alpha`), returns `false` — the
  conservative tone-map (see the design doc, decision 2).
  """
  @spec supports_hdr?(t(), source_format() | nil) :: boolean()
  def supports_hdr?(%__MODULE__{hdr: :preserve} = policy, source_format) do
    case resolve(policy, source_format) do
      {:ok, %Resolved{format: format}} -> Format.supports_hdr?(format)
      _other -> false
    end
  end

  def supports_hdr?(%__MODULE__{}, _source_format), do: false

  @spec ensure_capable(t(), keyword()) :: :ok | {:error, {:unsupported_output_format, format()}}
  def ensure_capable(%__MODULE__{mode: {:explicit, format}}, opts) do
    if Capabilities.supports?(format, opts) do
      :ok
    else
      {:error, {:unsupported_output_format, format}}
    end
  end

  def ensure_capable(%__MODULE__{mode: :source}, _opts), do: :ok

  # Only baseline formats pass through as-is. Modern source formats (avif/webp)
  # are reached here only when the client accepted no modern format, so passing
  # them through would serve an unaccepted (possibly undecodable) format; route
  # them and source-only formats to the raster-by-alpha path instead.
  defp resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    cond do
      source_format in @passthrough_source_formats -> {:selected, source_format, :source}
      Format.source_format?(source_format) -> {:needs_final_image_alpha, :source}
      true -> {:error, :source_format_required}
    end
  end

  defp resolve_final_image_alpha(%__MODULE__{} = policy, true),
    do: resolved(policy, :png)

  defp resolve_final_image_alpha(%__MODULE__{} = policy, false),
    do: resolved(policy, :jpeg)

  defp resolved(%__MODULE__{} = policy, format) do
    %Resolved{
      format: format,
      quality: effective_quality(policy, format),
      response_headers: policy.headers,
      strip_metadata: policy.strip_metadata,
      keep_copyright: policy.keep_copyright,
      color_profile: policy.color_profile,
      flatten_background: policy.flatten_background,
      quality_search: resolve_search(policy, format),
      quality_search_max_iterations: policy.quality_search_max_iterations,
      max_bytes: policy.max_bytes,
      encoder_options: Map.get(policy.encoder_options, format)
    }
  end

  defp resolve_search(%__MODULE__{quality_search: :none}, _format), do: :none

  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Size{} = s}, format) do
    %RQS.Size{
      target: s.target,
      min_quality: s.url_min_quality || Map.get(s.format_min, format, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, format, s.max_quality),
      max_resolution: s.max_resolution
    }
  end

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch.Ssimulacra2{} = s} = policy,
         format
       ) do
    %RQS.Ssimulacra2{
      target: s.target,
      min_quality: s.url_min_quality || Map.get(s.format_min, format, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, format, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution,
      quality_search_offsets: %{
        photo: Output.offset_for(policy.quality_search_offsets, format, :photo),
        graphic: Output.offset_for(policy.quality_search_offsets, format, :graphic)
      }
    }
  end

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{} = s},
         :jpeg_xl
       ) do
    %RQS.NativeJxlButteraugli{
      target: s.target,
      min_quality: s.url_min_quality || Map.get(s.format_min, :jpeg_xl, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, :jpeg_xl, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution
    }
  end

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{} = s},
         format
       ) do
    %RQS.Butteraugli{
      target: s.target,
      min_quality: s.url_min_quality || Map.get(s.format_min, format, s.min_quality),
      max_quality: s.url_max_quality || Map.get(s.format_max, format, s.max_quality),
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution
    }
  end

  defp effective_quality(%__MODULE__{quality: {:quality, _value} = quality}, _format),
    do: quality

  defp effective_quality(
         %__MODULE__{quality: :default, format_qualities: format_qualities} = policy,
         format
       ) do
    case Map.get(format_qualities, format) do
      {:quality, _value} = quality -> quality
      _other -> default_for(policy, format)
    end
  end

  defp default_for(%__MODULE__{}, format) when format in @lossless_default_formats, do: :default
  defp default_for(%__MODULE__{default_quality: default_quality}, _format), do: default_quality

  defp output_mode(%__MODULE__{mode: {:explicit, _format}}), do: :explicit
  defp output_mode(%__MODULE__{mode: :source}), do: :automatic

  defp stop_metadata({:ok, %Resolved{format: format}}),
    do: %{result: :ok, output_format: format}

  defp stop_metadata({:error, reason}),
    do: %{result: :output_error, error: Error.tag(reason)}

  defp search_iteration_identity(%__MODULE__{quality_search: :none, max_bytes: nil}), do: nil

  defp search_iteration_identity(%__MODULE__{mode: {:explicit, :png}}), do: nil

  defp search_iteration_identity(%__MODULE__{
         mode: {:explicit, :webp},
         encoder_options: %{webp: %Output.WebpOptions{lossless: true}}
       }),
       do: nil

  defp search_iteration_identity(%__MODULE__{
         mode: :source,
         modern_candidates: [:webp | _rest],
         encoder_options: %{webp: %Output.WebpOptions{lossless: true}}
       }),
       do: nil

  defp search_iteration_identity(
         %__MODULE__{quality_search: %Output.QualitySearch.Butteraugli{}, max_bytes: nil} = policy
       ) do
    case identity_selection(policy) do
      {:explicit, :jpeg_xl} -> nil
      {:auto_head, :jpeg_xl} -> nil
      _iterative -> policy.quality_search_max_iterations
    end
  end

  defp search_iteration_identity(%__MODULE__{quality_search_max_iterations: iterations}),
    do: iterations

  # Canonicalized quality-search identity: structs must not reach the digest
  # directly (MaterialDigest.canonicalize/1 maps over maps but structs aren't
  # Enumerable), and format_min/format_max maps are sorted to plain lists so
  # equal-meaning searches always digest identically.
  defp quality_search_identity(:none), do: :none

  defp quality_search_identity(%Output.QualitySearch.Size{} = s) do
    [
      metric: :size,
      target: s.target,
      min_quality: s.min_quality,
      max_quality: s.max_quality,
      url_min_quality: s.url_min_quality,
      url_max_quality: s.url_max_quality,
      max_resolution: s.max_resolution,
      format_min: Enum.sort(Map.to_list(s.format_min)),
      format_max: Enum.sort(Map.to_list(s.format_max))
    ]
  end

  defp quality_search_identity(%Output.QualitySearch.Ssimulacra2{} = s),
    do: quality_metric_identity(:ssimulacra2, s)

  defp quality_search_identity(%Output.QualitySearch.Butteraugli{} = s),
    do: quality_metric_identity(:butteraugli, s)

  defp quality_metric_identity(metric, s) do
    [
      metric: metric,
      target: s.target,
      min_quality: s.min_quality,
      max_quality: s.max_quality,
      url_min_quality: s.url_min_quality,
      url_max_quality: s.url_max_quality,
      allowed_error: s.allowed_error,
      max_resolution: s.max_resolution,
      format_min: Enum.sort(Map.to_list(s.format_min)),
      format_max: Enum.sort(Map.to_list(s.format_max))
    ]
  end

  # Encoder-option structs must be flattened to plain maps before the digest,
  # for the same reason as quality-search structs above.
  defp encoder_options_identity(map),
    do: Map.new(map, fn {format, struct} -> {format, Map.from_struct(struct)} end)
end

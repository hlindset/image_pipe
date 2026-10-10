defmodule ImagePipe.Output.Policy do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Spec.Output, as: SpecOutput
  alias ImagePipe.Telemetry

  # Qualities the search may try per format, wide enough for the targets people
  # use (bench/autoquality.md, Part N). They only stop pathological images from
  # running off to the ends of the scale.
  @search_rails %{jpeg: {25, 95}, webp: {25, 95}, avif: {20, 90}}
  @default_search_rails {25, 95}
  @search_tolerance 0.5

  @encoder_option_config %{
    jpeg: :jpeg_options,
    png: :png_options,
    webp: :webp_options,
    avif: :avif_options
  }

  # Median quality that reaches each target, per format (Part N; AVIF without
  # chroma subsampling, Part P). The search
  # starts there, interpolating between targets and extending the end segments.
  @start_quality %{
    jpeg: [{70, 67}, {72, 71}, {75, 76}, {78, 82}, {80, 85}, {85, 90}],
    webp: [{70, 67}, {72, 74}, {75, 78}, {78, 83}, {80, 85}, {85, 90}],
    avif: [{70, 49}, {72, 50}, {75, 53}, {78, 56}, {80, 59}, {85, 71}]
  }

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
                default_quality: :default,
                quality_search: :none,
                fixed_quality_formats: [],
                max_bytes: nil,
                dpi: nil,
                encoder_options: %{},
                hdr: :tone_map,
                skip_formats: []
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
          quality_search:
            :none
            | Output.QualitySearch.t(),
          fixed_quality_formats: [format()],
          max_bytes: nil | pos_integer(),
          dpi: nil | 1..65_535,
          encoder_options: %{optional(format()) => struct()},
          hdr: Output.hdr(),
          skip_formats: [source_format()]
        }

  @type identity_selection() ::
          {:explicit, format()} | {:auto_head, format()} | :source_negotiated

  @doc """
  The output policy for a request's output options, the mount's
  configuration, and the request's `Accept` header.
  """
  @spec from_request(SpecOutput.t(), keyword(), String.t()) ::
          {:ok, t()} | {:error, {:invalid_output, term()}}
  def from_request(%SpecOutput{} = request, config, accept_header) do
    quality_search = resolve_quality_search(request, config)
    output = request_policy(request, config, accept_header, quality_search)

    with :ok <- validate_hdr_profile(output),
         :ok <- validate_lossless_webp_request(output, request),
         :ok <- validate_png_quality(output, request) do
      {:ok, output}
    else
      {:error, reason} -> {:error, {:invalid_output, reason}}
    end
  end

  defp request_mode(nil), do: :source
  defp request_mode(format), do: {:explicit, format}

  defp output_quality(nil), do: :default
  defp output_quality(quality), do: {:quality, quality}

  defp request_policy(request, config, accept_header, quality_search) do
    configured_strip = Keyword.fetch!(config, :strip_metadata)

    {strip_metadata, keep_copyright} =
      metadata_policy(
        request.metadata,
        configured_strip,
        configured_strip and Keyword.fetch!(config, :keep_copyright)
      )

    {modern_candidates, headers} = negotiation(request.format, accept_header, config)

    %__MODULE__{
      mode: request_mode(request.format),
      modern_candidates: modern_candidates,
      headers: headers,
      quality: output_quality(request.quality),
      default_quality: {:quality, Keyword.fetch!(config, :quality)},
      format_qualities: format_qualities(request, config),
      strip_metadata: strip_metadata,
      keep_copyright: keep_copyright,
      dpi: dpi(request.dpi, strip_metadata, config),
      color_profile:
        request.color_profile ||
          color_profile_policy(Keyword.fetch!(config, :strip_color_profile)),
      hdr: request.hdr || hdr_policy(Keyword.fetch!(config, :preserve_hdr)),
      encoder_options:
        merge_encoder_options(encoder_options_from_config(config), request.encoder_options),
      quality_search: quality_search,
      fixed_quality_formats: request.format_qualities |> Map.keys() |> Enum.sort(),
      max_bytes: request.max_bytes
    }
  end

  defp negotiation(nil, accept_header, config) do
    case Negotiation.negotiable?(config) do
      true -> {Negotiation.modern_candidates(accept_header, config), [{"vary", "Accept"}]}
      false -> {[], []}
    end
  end

  defp negotiation(_format, _accept_header, _config), do: {[], []}

  defp encoder_options_from_config(config) do
    for {format, key} <- @encoder_option_config,
        struct = Keyword.get(config, key),
        not is_nil(struct),
        not struct.__struct__.all_nil?(struct),
        into: %{},
        do: {format, struct}
  end

  # A request's `q` replaces the host's per-format qualities, and the request's
  # own `format-q` wins over its `q`.
  defp format_qualities(%SpecOutput{quality: nil} = request, config) do
    config
    |> Keyword.fetch!(:format_quality)
    |> normalize_format_qualities()
    |> Map.merge(request.format_qualities)
  end

  defp format_qualities(request, _config), do: request.format_qualities

  defp normalize_format_qualities(map),
    do: Map.new(map, fn {format, quality} -> {format, {:quality, quality}} end)

  defp color_profile_policy(true), do: :strip
  defp color_profile_policy(false), do: :preserve_source

  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map

  defp resolve_quality_search(%SpecOutput{quality: quality}, _config)
       when not is_nil(quality),
       do: :none

  defp resolve_quality_search(%SpecOutput{autoquality: autoquality}, config),
    do: QualitySearch.resolve(autoquality, config)

  defp metadata_policy(nil, strip_metadata, keep_copyright),
    do: {strip_metadata, keep_copyright}

  defp metadata_policy(:strip, _strip_metadata, _keep_copyright), do: {true, false}
  defp metadata_policy(:copyright, _strip_metadata, _keep_copyright), do: {true, true}
  defp metadata_policy(:keep, _strip_metadata, _keep_copyright), do: {false, false}

  # Density is metadata: stripping replaces the source value with the host's.
  defp dpi(nil, true, config), do: Keyword.fetch!(config, :stripped_dpi)
  defp dpi(nil, false, _config), do: nil
  defp dpi(dpi, _strip_metadata, _config), do: dpi

  defp validate_hdr_profile(%__MODULE__{color_profile: {:convert, _target}, hdr: :preserve}),
    do: {:error, :hdr_profile_conversion}

  defp validate_hdr_profile(%__MODULE__{}), do: :ok

  defp merge_encoder_options(configured, requested) do
    configured
    |> Map.merge(requested, fn _format, base, overlay ->
      base.__struct__.merge(base, overlay)
    end)
    |> Map.reject(fn {_format, options} -> options.__struct__.all_nil?(options) end)
  end

  defp validate_lossless_webp_request(
         %__MODULE__{
           mode: {:explicit, :webp},
           encoder_options: %{webp: %Output.WebpOptions{lossless: true}}
         },
         %SpecOutput{autoquality: autoquality, max_bytes: max_bytes}
       ) do
    if enabled_url_autoquality?(autoquality) or not is_nil(max_bytes) do
      {:error, :lossless_webp_quality_search}
    else
      :ok
    end
  end

  defp validate_lossless_webp_request(%__MODULE__{}, %SpecOutput{}), do: :ok

  # A PNG quality only sets palette quantization.
  defp validate_png_quality(%__MODULE__{} = output, %SpecOutput{} = request) do
    png_quality? =
      Map.has_key?(request.format_qualities, :png) or
        (output.mode == {:explicit, :png} and not is_nil(request.quality))

    if png_quality? and not png_palette?(output) do
      {:error, :png_quality_without_palette}
    else
      :ok
    end
  end

  defp enabled_url_autoquality?(autoquality), do: autoquality not in [nil, false]

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
      fixed_quality_formats: policy.fixed_quality_formats,
      max_bytes: policy.max_bytes,
      strip_metadata: policy.strip_metadata,
      keep_copyright: policy.keep_copyright,
      dpi: policy.dpi,
      color_profile: policy.color_profile,
      hdr: policy.hdr,
      encoder_options: encoder_options_identity(policy.encoder_options),
      skip_formats: policy.skip_formats
    ]
  end

  @doc """
  Narrows the host's skip-processing formats to the source formats this
  request may deliver unchanged: every listed format without an explicit
  `format`, or only the explicit format when it is listed.
  """
  @spec put_skip_formats(t(), [source_format()]) :: t()
  def put_skip_formats(%__MODULE__{mode: :source} = policy, formats),
    do: %{policy | skip_formats: formats |> Enum.uniq() |> Enum.sort()}

  def put_skip_formats(%__MODULE__{mode: {:explicit, format}} = policy, formats),
    do: %{policy | skip_formats: Enum.filter([format], &(&1 in formats))}

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

  # `writable` is the formats the libvips build can write.
  @spec ensure_capable(t(), [format()]) :: :ok | {:error, {:unsupported_output_format, format()}}
  def ensure_capable(policy, writable \\ Capabilities.writable())

  def ensure_capable(%__MODULE__{mode: {:explicit, format}}, writable) do
    if format in writable do
      :ok
    else
      {:error, {:unsupported_output_format, format}}
    end
  end

  def ensure_capable(%__MODULE__{mode: :source}, _writable), do: :ok

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
      dpi: policy.dpi,
      color_profile: policy.color_profile,
      quality_search: resolve_search(policy, format),
      max_bytes: policy.max_bytes,
      encoder_options: Map.get(policy.encoder_options, format)
    }
  end

  defp resolve_search(%__MODULE__{quality_search: :none}, _format), do: :none

  # The request's own quality for a format turns the search off for it.
  defp resolve_search(%__MODULE__{} = policy, format) do
    case format in policy.fixed_quality_formats do
      true -> :none
      false -> search(policy.quality_search, format)
    end
  end

  defp search(%Output.QualitySearch{} = s, format) do
    {min_quality, max_quality} = Map.get(@search_rails, format, @default_search_rails)

    %RQS.Ssimulacra2{
      target: s.target,
      min_quality: min_quality,
      max_quality: max_quality,
      start_quality: start_quality(format, s.target, min_quality, max_quality),
      allowed_error: @search_tolerance
    }
  end

  defp start_quality(format, target, min_quality, max_quality) do
    case Map.fetch(@start_quality, format) do
      {:ok, points} ->
        points |> interpolate(target) |> round() |> max(min_quality) |> min(max_quality)

      :error ->
        nil
    end
  end

  defp interpolate([{t1, q1}, {t2, q2} | rest], target) when target <= t2 or rest == [],
    do: q1 + (target - t1) * (q2 - q1) / (t2 - t1)

  defp interpolate([_ | rest], target), do: interpolate(rest, target)

  # libvips uses a PNG quality only to quantize a palette.
  defp effective_quality(%__MODULE__{} = policy, :png) do
    case png_palette?(policy) do
      true -> requested_quality(policy, :png)
      false -> :default
    end
  end

  defp effective_quality(policy, format), do: requested_quality(policy, format)

  @doc false
  @spec png_palette?(t()) :: boolean()
  def png_palette?(%__MODULE__{encoder_options: %{png: %{palette: true}}}), do: true
  def png_palette?(%__MODULE__{}), do: false

  defp requested_quality(%__MODULE__{format_qualities: format_qualities} = policy, format) do
    case {Map.get(format_qualities, format), policy.quality} do
      {{:quality, _value} = quality, _quality} -> quality
      {nil, {:quality, _value} = quality} -> quality
      {nil, :default} -> default_for(policy, format)
    end
  end

  defp default_for(%__MODULE__{}, format) when format in @lossless_default_formats, do: :default
  defp default_for(%__MODULE__{default_quality: default_quality}, _format), do: default_quality

  defp output_mode(%__MODULE__{mode: {:explicit, _format}}), do: :explicit
  defp output_mode(%__MODULE__{mode: :source}), do: :automatic

  defp stop_metadata({:ok, %Resolved{format: format}}),
    do: %{result: :ok, output_format: format}

  defp stop_metadata({:error, reason}),
    do: %{result: :output_error, error: Telemetry.error_tag(reason)}

  defp quality_search_identity(:none), do: :none

  defp quality_search_identity(%Output.QualitySearch{} = s),
    do: [target: s.target]

  defp encoder_options_identity(map),
    do: Map.new(map, fn {format, struct} -> {format, Map.from_struct(struct)} end)
end

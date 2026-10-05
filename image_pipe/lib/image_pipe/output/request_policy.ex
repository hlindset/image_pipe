defmodule ImagePipe.Output.RequestPolicy do
  @moduledoc false

  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Spec.Output, as: SpecOutput

  @encoder_option_config %{
    jpeg: :jpeg_options,
    png: :png_options,
    webp: :webp_options,
    avif: :avif_options
  }

  @spec resolve(SpecOutput.t(), keyword(), String.t()) ::
          {:ok, Policy.t()} | {:error, {:invalid_output, term()}}
  def resolve(%SpecOutput{} = request, config, accept_header) do
    quality_search = resolve_quality_search(request, config)
    output = policy(request, config, accept_header, quality_search)

    with :ok <- validate_hdr_profile(output),
         :ok <- validate_lossless_webp_request(output, request),
         :ok <- validate_png_quality(output, request) do
      {:ok, output}
    else
      {:error, reason} -> {:error, {:invalid_output, reason}}
    end
  end

  defp output_mode(nil), do: :source
  defp output_mode(format), do: {:explicit, format}

  defp output_quality(nil), do: :default
  defp output_quality(quality), do: {:quality, quality}

  defp policy(request, config, accept_header, quality_search) do
    configured_strip = Keyword.fetch!(config, :strip_metadata)

    {strip_metadata, keep_copyright} =
      metadata_policy(
        request.metadata,
        configured_strip,
        configured_strip and Keyword.fetch!(config, :keep_copyright)
      )

    {modern_candidates, headers} = negotiation(request.format, accept_header, config)

    %Policy{
      mode: output_mode(request.format),
      modern_candidates: modern_candidates,
      headers: headers,
      quality: output_quality(request.quality),
      default_quality: {:quality, Keyword.fetch!(config, :quality)},
      format_qualities:
        Map.merge(
          normalize_format_qualities(Keyword.fetch!(config, :format_quality)),
          request.format_qualities
        ),
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

  defp validate_hdr_profile(%Policy{color_profile: {:convert, _target}, hdr: :preserve}),
    do: {:error, :hdr_profile_conversion}

  defp validate_hdr_profile(%Policy{}), do: :ok

  defp merge_encoder_options(configured, requested) do
    configured
    |> Map.merge(requested, fn _format, base, overlay ->
      base.__struct__.merge(base, overlay)
    end)
    |> Map.reject(fn {_format, options} -> options.__struct__.all_nil?(options) end)
  end

  defp validate_lossless_webp_request(
         %Policy{
           mode: {:explicit, :webp},
           encoder_options: %{webp: %PlanOutput.WebpOptions{lossless: true}}
         },
         %SpecOutput{autoquality: autoquality, max_bytes: max_bytes}
       ) do
    if enabled_url_autoquality?(autoquality) or not is_nil(max_bytes) do
      {:error, :lossless_webp_quality_search}
    else
      :ok
    end
  end

  defp validate_lossless_webp_request(%Policy{}, %SpecOutput{}), do: :ok

  # A PNG quality only sets palette quantization.
  defp validate_png_quality(%Policy{} = output, %SpecOutput{} = request) do
    png_quality? =
      Map.has_key?(request.format_qualities, :png) or
        (output.mode == {:explicit, :png} and not is_nil(request.quality))

    if png_quality? and not Policy.png_palette?(output) do
      {:error, :png_quality_without_palette}
    else
      :ok
    end
  end

  defp enabled_url_autoquality?(autoquality), do: autoquality not in [nil, false]
end

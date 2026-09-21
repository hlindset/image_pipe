defmodule ImagePipe.Output.RequestPolicy do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Request.Output, as: RequestOutput

  @encoder_option_config %{
    jpeg: :jpeg_options,
    png: :png_options,
    webp: :webp_options,
    avif: :avif_options,
    jpeg_xl: :jxl_options
  }

  @spec resolve(RequestOutput.t(), keyword(), String.t()) ::
          {:ok, Policy.t() | nil} | {:error, {:invalid_output, term()}}
  def resolve(%RequestOutput{terminal: terminal}, _config, _accept_header)
      when terminal in [:blurhash, :lqip_css, :info] do
    {:ok, nil}
  end

  def resolve(%RequestOutput{} = request, config, accept_header) do
    with {:ok, quality_search} <- resolve_quality_search(request, config),
         output = policy(request, config, accept_header, quality_search),
         :ok <- validate_hdr_profile(output),
         :ok <- validate_lossless_webp_request(output, request),
         :ok <- validate_brackets(output, config) do
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
      color_profile:
        request.color_profile ||
          color_profile_policy(Keyword.fetch!(config, :strip_color_profile)),
      hdr: request.hdr || hdr_policy(Keyword.fetch!(config, :preserve_hdr)),
      encoder_options:
        merge_encoder_options(encoder_options_from_config(config), request.encoder_options),
      quality_search: quality_search,
      quality_search_max_iterations: Keyword.fetch!(config, :autoquality_max_iterations),
      max_bytes: request.max_bytes
    }
  end

  defp negotiation(nil, accept_header, config),
    do: {Negotiation.modern_candidates(accept_header, config), [{"vary", "Accept"}]}

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

  defp resolve_quality_search(%RequestOutput{quality: quality}, _config)
       when not is_nil(quality),
       do: {:ok, :none}

  defp resolve_quality_search(%RequestOutput{autoquality: nil}, config),
    do: QualitySearch.from_config(config)

  defp resolve_quality_search(%RequestOutput{autoquality: :none}, _config), do: {:ok, :none}

  defp resolve_quality_search(%RequestOutput{autoquality: {method, fields}}, config),
    do: QualitySearch.build(method, fields, config)

  defp metadata_policy(nil, strip_metadata, keep_copyright),
    do: {strip_metadata, keep_copyright}

  defp metadata_policy(:strip, _strip_metadata, _keep_copyright), do: {true, false}
  defp metadata_policy(:copyright, _strip_metadata, _keep_copyright), do: {true, true}
  defp metadata_policy(:keep, _strip_metadata, _keep_copyright), do: {false, false}

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
         %RequestOutput{autoquality: autoquality, max_bytes: max_bytes}
       ) do
    if enabled_url_autoquality?(autoquality) or not is_nil(max_bytes) do
      {:error, :lossless_webp_quality_search}
    else
      :ok
    end
  end

  defp validate_lossless_webp_request(%Policy{}, %RequestOutput{}), do: :ok

  defp enabled_url_autoquality?({_method, _fields}), do: true

  defp enabled_url_autoquality?(_autoquality), do: false

  defp validate_brackets(%Policy{quality_search: :none}, _config), do: :ok

  defp validate_brackets(%Policy{mode: mode, quality_search: search}, config) do
    mode
    |> possible_formats(config)
    |> Enum.filter(&Format.supports_quality?/1)
    |> Enum.reduce_while(:ok, fn format, :ok ->
      min_quality =
        search.url_min_quality || Map.get(search.format_min, format, search.min_quality)

      max_quality =
        search.url_max_quality || Map.get(search.format_max, format, search.max_quality)

      if min_quality <= max_quality do
        {:cont, :ok}
      else
        {:halt, {:error, {:inverted_autoquality_bracket, format}}}
      end
    end)
  end

  defp possible_formats(:source, config) do
    Enum.filter(Format.output_formats(), &automatic_format_enabled?(&1, config))
  end

  defp possible_formats({:explicit, format}, _config), do: [format]

  defp automatic_format_enabled?(:jpeg_xl, config),
    do: Keyword.get(config, :auto_jpeg_xl, true)

  defp automatic_format_enabled?(:avif, config), do: Keyword.get(config, :auto_avif, true)
  defp automatic_format_enabled?(:webp, config), do: Keyword.get(config, :auto_webp, true)
  defp automatic_format_enabled?(_baseline, _config), do: true
end

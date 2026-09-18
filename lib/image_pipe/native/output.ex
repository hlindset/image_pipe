defmodule ImagePipe.Native.Output do
  @moduledoc false

  alias ImagePipe.Config
  alias ImagePipe.Format
  alias ImagePipe.Native.Request.Output, as: RequestOutput
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.QualitySearch

  @spec resolve(RequestOutput.t(), keyword()) ::
          {:ok, PlanOutput.t()} | {:error, {:invalid_output, term()}}
  def resolve(%RequestOutput{terminal: terminal}, _config)
      when terminal in [:blurhash, :info] do
    {:ok, %PlanOutput{mode: :automatic}}
  end

  def resolve(%RequestOutput{} = request, config) when is_list(config) do
    with {:ok, configured} <-
           Config.apply_to_output(base_output(request), disable_host_autoquality(config)),
         {:ok, quality_search} <- resolve_quality_search(request, config),
         output = overlay_request(configured, request, quality_search),
         :ok <- validate_hdr_profile(output),
         :ok <- validate_lossless_webp_request(output, request),
         :ok <- validate_brackets(output, config) do
      {:ok, output}
    else
      {:error, reason} -> {:error, {:invalid_output, reason}}
    end
  end

  defp base_output(%RequestOutput{format: format, quality: quality}) do
    %PlanOutput{
      mode: output_mode(format),
      quality: output_quality(quality)
    }
  end

  defp output_mode(nil), do: :automatic
  defp output_mode(format), do: {:explicit, format}

  defp output_quality(nil), do: :default
  defp output_quality(quality), do: {:quality, quality}

  defp disable_host_autoquality(config), do: Keyword.put(config, :autoquality_method, :none)

  defp resolve_quality_search(%RequestOutput{quality: quality}, _config)
       when not is_nil(quality),
       do: {:ok, :none}

  defp resolve_quality_search(%RequestOutput{autoquality: nil}, config),
    do: QualitySearch.from_config(config)

  defp resolve_quality_search(%RequestOutput{autoquality: :none}, _config), do: {:ok, :none}

  defp resolve_quality_search(%RequestOutput{autoquality: {method, fields}}, config),
    do: QualitySearch.build(method, fields, config)

  defp overlay_request(configured, request, quality_search) do
    {strip_metadata, keep_copyright} =
      metadata_policy(request.metadata, configured.strip_metadata, configured.keep_copyright)

    %{
      configured
      | strip_metadata: strip_metadata,
        keep_copyright: keep_copyright,
        color_profile: request.color_profile || configured.color_profile,
        hdr: request.hdr || configured.hdr,
        format_qualities: Map.merge(configured.format_qualities, request.format_qualities),
        quality_search: quality_search,
        max_bytes: request.max_bytes,
        encoder_options:
          merge_encoder_options(configured.encoder_options, request.encoder_options)
    }
  end

  defp metadata_policy(nil, strip_metadata, keep_copyright),
    do: {strip_metadata, keep_copyright}

  defp metadata_policy(:strip, _strip_metadata, _keep_copyright), do: {true, false}
  defp metadata_policy(:copyright, _strip_metadata, _keep_copyright), do: {true, true}
  defp metadata_policy(:keep, _strip_metadata, _keep_copyright), do: {false, false}

  defp validate_hdr_profile(%PlanOutput{color_profile: {:convert, _target}, hdr: :preserve}),
    do: {:error, :hdr_profile_conversion}

  defp validate_hdr_profile(%PlanOutput{}), do: :ok

  defp merge_encoder_options(configured, requested) do
    configured
    |> Map.merge(requested, fn _format, base, overlay ->
      base.__struct__.merge(base, overlay)
    end)
    |> Map.reject(fn {_format, options} -> options.__struct__.all_nil?(options) end)
  end

  defp validate_lossless_webp_request(
         %PlanOutput{
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

  defp validate_lossless_webp_request(%PlanOutput{}, %RequestOutput{}), do: :ok

  defp enabled_url_autoquality?({_method, _fields}), do: true

  defp enabled_url_autoquality?(_autoquality), do: false

  defp validate_brackets(%PlanOutput{quality_search: :none}, _config), do: :ok

  defp validate_brackets(%PlanOutput{mode: mode, quality_search: search}, config) do
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

  defp possible_formats(:automatic, config) do
    Enum.filter(Format.output_formats(), &automatic_format_enabled?(&1, config))
  end

  defp possible_formats({:explicit, format}, _config), do: [format]

  defp automatic_format_enabled?(:jpeg_xl, config),
    do: Keyword.get(config, :auto_jpeg_xl, true)

  defp automatic_format_enabled?(:avif, config), do: Keyword.get(config, :auto_avif, true)
  defp automatic_format_enabled?(:webp, config), do: Keyword.get(config, :auto_webp, true)
  defp automatic_format_enabled?(_baseline, _config), do: true
end

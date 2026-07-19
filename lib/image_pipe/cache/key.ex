defmodule ImagePipe.Cache.Key do
  @moduledoc """
  Deterministic cache key data for processed image responses.
  """

  import Plug.Conn, only: [fetch_cookies: 1, get_req_header: 2]

  alias ImagePipe.MaterialDigest
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.QualitySearch
  alias ImagePipe.Plan.Pipeline

  @schema_version 2
  @transform_key_data_version 1
  @representation_version 1
  @enforce_keys [:hash, :data]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          data: keyword()
        }

  @spec build(Plug.Conn.t(), Plan.t(), term(), keyword()) :: {:ok, t()}
  def build(conn, %Plan{} = plan, source_identity, opts \\ []) when is_list(opts) do
    {:ok, plan_material} = plan_material(plan, opts)
    {:ok, output} = output_data(conn, plan.output, opts)

    data =
      [
        schema_version: @schema_version,
        source_identity: source_identity
      ] ++
        replace_keyword_value(plan_material, :output, output) ++
        [
          selected_headers: selected_headers(conn, opts),
          selected_cookies: selected_cookies(conn, opts)
        ]

    {:ok, %__MODULE__{hash: hash(data), data: data}}
  end

  @doc false
  @spec plan_material(Plan.t(), keyword()) :: {:ok, keyword()}
  def plan_material(%Plan{} = plan, opts) do
    {:ok, output} = output_plan_data(plan.output, opts)

    {:ok,
     [
       pipelines: pipelines_data(plan.pipelines),
       transform: transform_data(),
       detector: Keyword.get(opts, :detector_identity),
       output: output,
       auto_rotate: plan.auto_rotate,
       representation: representation_data(plan.render),
       cache: cache_data(plan.cachebuster)
     ]}
  end

  @doc false
  @spec representation_version() :: pos_integer()
  def representation_version, do: @representation_version

  defp pipelines_data(pipelines) do
    Enum.map(pipelines, fn %Pipeline{operations: operations} ->
      Enum.map(operations, &KeyData.data/1)
    end)
  end

  defp transform_data, do: [key_data_version: @transform_key_data_version]

  defp representation_data(:image), do: [version: @representation_version]

  defp representation_data({:custom, module, params}),
    do: [version: @representation_version, render: module, params: params]

  # A custom render carries no image output; it contributes no output key data
  # (the render identity is carried by `representation_data/1` instead).
  defp output_plan_data(nil, _opts), do: {:ok, []}

  defp output_plan_data(%Output{mode: :automatic} = output, opts) do
    {:ok,
     [
       mode: :automatic,
       auto: [
         jpeg_xl: Keyword.get(opts, :auto_jpeg_xl, true),
         avif: Keyword.get(opts, :auto_avif, true),
         webp: Keyword.get(opts, :auto_webp, true)
       ],
       quality: output.quality,
       format_qualities: output.format_qualities,
       quality_search: quality_search_key(output.quality_search),
       max_bytes: output.max_bytes,
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr,
       flatten_background: Color.key_data(output.flatten_background),
       encoder_options: encoder_options_key(output.encoder_options)
     ]}
  end

  defp output_plan_data(%Output{mode: {:explicit, format}} = output, _opts) do
    {:ok,
     [
       mode: :explicit,
       format: format,
       quality: output.quality,
       format_qualities: output.format_qualities,
       quality_search: quality_search_key(output.quality_search),
       max_bytes: output.max_bytes,
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr,
       flatten_background: Color.key_data(output.flatten_background),
       # Explicit format: only the selected format's options shape the bytes, so
       # narrow the digest (Policy.resolved/2 forwards only Map.get(.., format)).
       encoder_options: encoder_options_key(Map.take(output.encoder_options, [format]))
     ]}
  end

  defp output_data(conn, %Output{mode: :automatic} = output, opts) do
    accept_header = conn |> get_req_header("accept") |> Enum.join(",")

    {:ok,
     [
       mode: :automatic,
       modern_candidates: Negotiation.modern_candidates(accept_header, opts),
       auto: [
         jpeg_xl: Keyword.get(opts, :auto_jpeg_xl, true),
         avif: Keyword.get(opts, :auto_avif, true),
         webp: Keyword.get(opts, :auto_webp, true)
       ],
       quality: output.quality,
       format_qualities: output.format_qualities,
       quality_search: quality_search_key(output.quality_search),
       max_bytes: output.max_bytes,
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr,
       flatten_background: Color.key_data(output.flatten_background),
       encoder_options: encoder_options_key(output.encoder_options)
     ]}
  end

  defp output_data(_conn, nil, opts), do: output_plan_data(nil, opts)

  defp output_data(_conn, %Output{} = output, opts), do: output_plan_data(output, opts)

  # `max_resolution` selects which bytes get stored, not whether they get generated:
  # above it the autoquality search is skipped and base-quality bytes ship, below it
  # searched-quality bytes ship. Both are successful 200s with different bytes, so —
  # like the per-format clamps — it is stored identity and enters both the key and the
  # ETag; omitting it would let a config change serve a stale 304. Per-format clamps
  # are sorted for canonical equality.
  # Encoder-option structs must be flattened to plain maps before the digest
  # (MaterialDigest.canonicalize/1 Enum.maps over maps; structs aren't Enumerable).
  defp encoder_options_key(map),
    do: Map.new(map, fn {format, struct} -> {format, Map.from_struct(struct)} end)

  defp quality_search_key(:none), do: :none

  defp quality_search_key(%QualitySearch.Size{} = s) do
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

  defp quality_search_key(%QualitySearch.Ssimulacra2{} = s),
    do: quality_metric_key(:ssimulacra2, s)

  defp quality_search_key(%QualitySearch.Butteraugli{} = s),
    do: quality_metric_key(:butteraugli, s)

  defp quality_metric_key(metric, s) do
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

  defp replace_keyword_value(keyword, key, value) do
    Enum.map(keyword, fn
      {^key, _old_value} -> {key, value}
      entry -> entry
    end)
  end

  defp cache_data(cachebuster), do: [cachebuster: cachebuster]

  defp selected_headers(conn, opts) do
    opts
    |> Keyword.get(:key_headers, [])
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name -> {name, get_req_header(conn, name)} end)
  end

  defp selected_cookies(conn, opts) do
    conn = fetch_cookies(conn)

    opts
    |> Keyword.get(:key_cookies, [])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case Map.fetch(conn.req_cookies, name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
  end

  defp hash(data) do
    data
    |> MaterialDigest.of()
    |> Base.encode16(case: :lower)
  end
end

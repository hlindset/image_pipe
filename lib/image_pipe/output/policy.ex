defmodule ImagePipe.Output.Policy do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output

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
                max_bytes: nil,
                quality_search_offsets: Output.default_quality_search_offsets()
              ]

  @passthrough_source_formats [:jpeg, :png]

  # Lossless output formats do not take the configured numeric default quality
  # (a numeric Q would trigger PNG quantization). An explicit URL q/fq still
  # applies; only the implicit global default is gated.
  @lossless_default_formats [:png]

  @type format() :: Format.output_format()
  @type source_format() :: Format.source_format()
  @type quality() :: :default | {:quality, 1..100}
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
          max_bytes: nil | pos_integer(),
          quality_search_offsets: Output.quality_search_offsets()
        }

  @spec from_output_plan(Plug.Conn.t(), Output.t(), keyword()) :: t()
  def from_output_plan(%Plug.Conn{} = conn, %Output{mode: :automatic} = output, opts) do
    %__MODULE__{
      mode: :source,
      modern_candidates: Negotiation.modern_candidates(accept_header(conn), opts),
      headers: automatic_headers(),
      quality: output.quality,
      format_qualities: output.format_qualities,
      default_quality: output.default_quality,
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright,
      color_profile: output.color_profile,
      flatten_background: output.flatten_background,
      quality_search: output.quality_search,
      max_bytes: output.max_bytes,
      quality_search_offsets: output.quality_search_offsets
    }
  end

  def from_output_plan(%Plug.Conn{}, %Output{mode: {:explicit, format}} = output, _opts) do
    %__MODULE__{
      mode: {:explicit, format},
      modern_candidates: [],
      headers: [],
      quality: output.quality,
      format_qualities: output.format_qualities,
      default_quality: output.default_quality,
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright,
      color_profile: output.color_profile,
      flatten_background: output.flatten_background,
      quality_search: output.quality_search,
      max_bytes: output.max_bytes,
      quality_search_offsets: output.quality_search_offsets
    }
  end

  defp resolve_before_source_fetch(%__MODULE__{mode: {:explicit, format}}),
    do: {:selected, format, :explicit}

  defp resolve_before_source_fetch(%__MODULE__{
         mode: :source,
         modern_candidates: [format | _rest]
       }),
       do: {:selected, format, :auto}

  defp resolve_before_source_fetch(%__MODULE__{mode: :source, modern_candidates: []}),
    do: :needs_source_format

  @spec resolve(t(), source_format() | nil) ::
          {:ok, Resolved.t()}
          | {:error, :source_format_required}
          | {:needs_final_image_alpha, :source}
  def resolve(%__MODULE__{} = policy, source_format) do
    case resolve_before_source_fetch(policy) do
      {:selected, format, _reason} ->
        {:ok, resolved(policy, format)}

      :needs_source_format ->
        case resolve_source_format(policy, source_format) do
          {:selected, format, _reason} -> {:ok, resolved(policy, format)}
          {:needs_final_image_alpha, _reason} = pending -> pending
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Whether the HDR working space should be kept (`Plan.Output.hdr == :preserve`
  and the output format carries HDR). Computed pre-transform so it can seed the
  input-color-management stage. In the one branch where the format is only known
  after the transform (`:needs_final_image_alpha`), returns `false` — the
  conservative tone-map (see the design doc, decision 2).
  """
  @spec supports_hdr?(t(), Output.t(), source_format() | nil) :: boolean()
  def supports_hdr?(%__MODULE__{} = policy, %Output{hdr: :preserve}, source_format) do
    case resolve(policy, source_format) do
      {:ok, %Resolved{format: format}} -> Format.supports_hdr?(format)
      _other -> false
    end
  end

  def supports_hdr?(%__MODULE__{}, %Output{}, _source_format), do: false

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

  @spec resolve_final_image_alpha(t(), boolean()) :: Resolved.t()
  def resolve_final_image_alpha(%__MODULE__{} = policy, true),
    do: resolved(policy, :png)

  def resolve_final_image_alpha(%__MODULE__{} = policy, false),
    do: resolved(policy, :jpeg)

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: [{"vary", "Accept"}]

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
      max_bytes: policy.max_bytes
    }
  end

  defp resolve_search(%__MODULE__{quality_search: :none}, _format), do: :none

  defp resolve_search(%__MODULE__{quality_search: %Output.QualitySearch.Size{} = s}, format) do
    %RQS.Size{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
      max_resolution: s.max_resolution
    }
  end

  defp resolve_search(
         %__MODULE__{quality_search: %Output.QualitySearch.Ssimulacra2{} = s} = policy,
         format
       ) do
    %RQS.Ssimulacra2{
      target: s.target,
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
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
      min_quality: Map.get(s.format_min, :jpeg_xl, s.min_quality),
      max_quality: Map.get(s.format_max, :jpeg_xl, s.max_quality),
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
      min_quality: Map.get(s.format_min, format, s.min_quality),
      max_quality: Map.get(s.format_max, format, s.max_quality),
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

  defp accept_header(conn), do: conn |> get_req_header("accept") |> Enum.join(",")
end

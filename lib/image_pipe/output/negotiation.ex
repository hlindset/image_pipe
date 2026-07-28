defmodule ImagePipe.Output.Negotiation do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias Plug.Conn.Utils

  @modern_mime_types Map.new(Format.output_mime_types()) |> Map.take(Format.modern_formats())

  # Server preference order among the modern formats. AVIF leads because, at the
  # ssim2 web-delivery quality target, it is both smaller and sharper than JPEG XL
  # (JXL only pulls ahead near visual-losslessness). A host may override the order
  # via the `:format_order` option; this diverges from imgproxy's documented
  # JXL > AVIF > WebP preference (see docs/imgproxy_support_matrix.md).
  @default_order [:avif, :jpeg_xl, :webp]

  @spec modern_candidates(String.t() | nil, keyword()) :: [:jpeg_xl | :avif | :webp]
  def modern_candidates(accept_header, opts \\ []) do
    case parse_accept(accept_header) do
      [] ->
        []

      entries ->
        opts
        |> enabled_modern_formats()
        |> Enum.flat_map(&modern_candidate(&1, entries))
    end
  end

  defp enabled_modern_formats(opts) do
    opts
    |> server_order()
    |> Enum.filter(&available?(&1, opts))
    |> Enum.map(&{&1, Map.fetch!(@modern_mime_types, &1)})
  end

  # A partial `:format_order` prioritizes the listed formats, then appends any
  # unlisted modern formats in the default order. Validation that the list holds
  # only distinct known formats lives at the mount-config boundary.
  defp server_order(opts) do
    case Keyword.get(opts, :format_order) do
      order when is_list(order) and order != [] -> order ++ (@default_order -- order)
      _ -> @default_order
    end
  end

  # A modern format is a candidate only when it is config-enabled AND the libvips
  # build can actually write it. Capability filtering here flows identically to
  # resolution, the cache key, and conditional-GET, since all three call this fn.
  defp available?(format, opts) do
    config_enabled?(format, opts) and Capabilities.supports?(format, opts)
  end

  defp config_enabled?(:jpeg_xl, opts), do: Keyword.get(opts, :auto_jpeg_xl, true)
  defp config_enabled?(:avif, opts), do: Keyword.get(opts, :auto_avif, true)
  defp config_enabled?(:webp, opts), do: Keyword.get(opts, :auto_webp, true)

  defp modern_candidate({format, mime_type}, entries) do
    if acceptable?(mime_type, entries), do: [format], else: []
  end

  defp acceptable?(mime_type, entries) do
    mime_type = Format.canonical_mime_type(mime_type)

    entries =
      Enum.map(entries, fn {accepted, quality} ->
        {Format.canonical_mime_type(accepted), quality}
      end)

    entries
    |> matching_qualities(mime_type)
    |> acceptable_quality?()
  end

  defp matching_qualities(entries, mime_type) do
    entries
    |> Enum.group_by(fn {accepted, _quality} -> match_specificity(accepted, mime_type) end)
    |> qualities_for_best_specificity()
  end

  defp qualities_for_best_specificity(qualities_by_specificity) do
    Enum.find_value([:exact], [], fn specificity ->
      quality_values(qualities_by_specificity, specificity)
    end)
  end

  defp quality_values(qualities_by_specificity, specificity) do
    qualities =
      qualities_by_specificity
      |> Map.get(specificity, [])
      |> Enum.map(fn {_accepted, quality} -> quality end)

    if qualities == [], do: nil, else: qualities
  end

  # Only an explicit `image/avif` / `image/webp` / `image/jxl` accepts a modern
  # format. The `image/*` wildcard does not: real Chrome/Firefox `<img>` requests
  # send `image/*` while being unable to decode JPEG XL, so honoring it would
  # serve undecodable bytes (imgproxy likewise keys off the explicit mime only).
  defp match_specificity(accepted, mime_type) do
    if accepted == mime_type, do: :exact, else: :none
  end

  # q=0 at the selected specificity is an explicit exclusion and wins over
  # duplicate positive entries of the same specificity.
  defp acceptable_quality?(qualities) do
    Enum.any?(qualities, &(&1 > 0)) and not Enum.any?(qualities, &(&1 == 0))
  end

  defp parse_accept(nil), do: []

  defp parse_accept(accept_header) do
    accept_header
    |> Utils.list()
    |> Enum.map(&parse_accept_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_accept_entry(entry) do
    case Utils.media_type(entry) do
      {:ok, type, subtype, params} -> {type <> "/" <> subtype, quality_from_params(params)}
      :error -> nil
    end
  end

  defp quality_from_params(params) do
    params
    |> Map.get("q", "1.0")
    |> parse_quality()
  end

  # An invalid or out-of-range weight (`q=1.5`, `q=abc`) is ignored, not treated
  # as an explicit `q=0` exclusion: drop the parameter and fall back to the
  # default q=1 (RFC 9110 §12.4.2). Only a well-formed in-range `q=0` excludes.
  defp parse_quality(value) do
    case value |> String.trim() |> Float.parse() do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> 1.0
    end
  end
end

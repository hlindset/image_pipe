defmodule ImagePipe.Format do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [],
    exports: [Detector]

  @output_formats [:avif, :webp, :jpeg, :png]
  @color_profile_formats [:avif, :webp, :jpeg, :png]
  @alpha_formats [:avif, :webp, :png]
  @hdr_formats [:avif, :png]
  @source_only_formats [:heif, :tiff, :jpeg2000, :jpeg_xl]
  @source_formats @output_formats ++ @source_only_formats
  @mime_types %{
    avif: "image/avif",
    webp: "image/webp",
    jpeg: "image/jpeg",
    png: "image/png"
  }
  @output_mime_types Enum.map(@output_formats, &{&1, Map.fetch!(@mime_types, &1)})

  @type output_format() :: :avif | :webp | :jpeg | :png
  @type source_only_format() :: :heif | :tiff | :jpeg2000 | :jpeg_xl
  @type source_format() :: output_format() | source_only_format()

  @spec output_formats() :: [output_format()]
  def output_formats, do: @output_formats

  @spec source_formats() :: [source_format()]
  def source_formats, do: @source_formats

  @spec source_only_formats() :: [source_only_format()]
  def source_only_formats, do: @source_only_formats

  @spec output_mime_types() :: keyword(String.t())
  def output_mime_types, do: @output_mime_types

  @spec output_mime_type_values() :: [String.t()]
  def output_mime_type_values, do: Keyword.values(@output_mime_types)

  @spec output_format?(term()) :: boolean()
  def output_format?(format), do: format in @output_formats

  @spec source_format?(term()) :: boolean()
  def source_format?(format), do: format in @source_formats

  @spec source_only_format?(term()) :: boolean()
  def source_only_format?(format), do: format in @source_only_formats

  @doc "Returns whether the format supports an embedded colour profile. Mirrors imgproxy's `SupportsColourProfile()`."
  @spec supports_color_profile?(output_format()) :: boolean()
  def supports_color_profile?(format), do: format in @color_profile_formats

  @doc "Returns whether the output format can carry an alpha channel. Mirrors imgproxy's `SupportsAlpha()` for the four output formats (AVIF/WebP/PNG true; JPEG false)."
  @spec supports_alpha?(output_format()) :: boolean()
  def supports_alpha?(format), do: format in @alpha_formats

  @doc "Returns whether the output format can carry HDR (16-bit). Mirrors imgproxy's `SupportsHDR()` for the four output formats (AVIF/PNG true; WebP/JPEG false)."
  @spec supports_hdr?(output_format()) :: boolean()
  def supports_hdr?(format), do: format in @hdr_formats

  @doc "Returns whether the output format has a lossy encode-quality knob the search can tune (AVIF/WebP/JPEG true; PNG false)."
  @spec supports_quality?(output_format()) :: boolean()
  def supports_quality?(format) when format in [:jpeg, :webp, :avif], do: true
  def supports_quality?(_format), do: false

  @spec suffix(String.t()) :: {:ok, String.t()} | {:error, term()}
  def suffix(mime_type) do
    with {:ok, _format} <- format_from_mime_type(mime_type),
         [extension | _rest] <- mime_type |> canonical_mime_type() |> MIME.extensions() do
      {:ok, "." <> extension}
    else
      {:error, _reason} = error -> error
      [] -> {:error, {:unsupported_output_format, normalize_mime_type(mime_type)}}
    end
  end

  @spec suffix!(String.t()) :: String.t()
  def suffix!(mime_type) do
    case suffix(mime_type) do
      {:ok, suffix} -> suffix
      {:error, reason} -> raise ArgumentError, "unsupported output MIME type: #{inspect(reason)}"
    end
  end

  @spec format_from_mime_type(term()) :: {:ok, output_format()} | {:error, term()}
  def format_from_mime_type(mime_type) do
    case normalize_mime_type(mime_type) do
      "image/jpg" -> {:ok, :jpeg}
      mime_type -> format_from_normalized_mime_type(mime_type)
    end
  end

  @spec mime_type(atom()) :: {:ok, String.t()} | :error
  def mime_type(format), do: Keyword.fetch(@output_mime_types, format)

  @spec mime_type!(atom()) :: String.t()
  def mime_type!(format), do: Keyword.fetch!(@output_mime_types, format)

  @spec canonical_mime_type(term()) :: term()
  def canonical_mime_type(mime_type) do
    case format_from_mime_type(mime_type) do
      {:ok, format} -> Keyword.fetch!(@output_mime_types, format)
      {:error, {:unsupported_output_format, _mime_type}} -> normalize_mime_type(mime_type)
    end
  end

  defp format_from_normalized_mime_type(mime_type) do
    case Enum.find(@output_mime_types, fn {_format, candidate_mime_type} ->
           candidate_mime_type == mime_type
         end) do
      {format, _mime_type} -> {:ok, format}
      nil -> {:error, {:unsupported_output_format, mime_type}}
    end
  end

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mime_type(mime_type), do: mime_type
end

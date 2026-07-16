defmodule ImagePipe.Dialect.Imgproxy.InfoRenderer do
  @moduledoc """
  Serializes `ImagePipe.Plan.SourceInfo` into imgproxy's /info JSON (Phase-1 header
  field set: format, mime_type, width, height, orientation, size). Owns imgproxy's
  wire spellings (per imgproxy `imagetype/defs.go`): HEIC is `"heic"`/`image/heif`,
  JPEG-XL is `"jxl"`/`image/jxl`; imgproxy has no `"heif"`/`"jpeg2000"` types. JP2 is
  a deliberate divergence (ImagePipe decodes it; imgproxy cannot). `width`/`height`
  are orientation-adjusted (swapped for EXIF 5-8).

  A phase-1 copy of the frozen `ImagePipe.Parser.Imgproxy.InfoRenderer`, minus
  the `ImagePipe.Renderer` behaviour: the inverted dialect owns its whole
  request chain and may not depend on the `Renderer` boundary, and rendering
  /info is not a neutral pluggable render here but this dialect's own terminal.
  So there is no `requires/1` (the chain's decode is the dialect's own), no
  `RenderContext` (the chain hands the `%SourceInfo{}` straight over), and no
  `{:ok, _}` wrapper — this cannot fail.
  """

  alias ImagePipe.Plan.SourceInfo

  # source atom => {imgproxy format string, imgproxy mime}
  @wire %{
    jpeg: {"jpeg", "image/jpeg"},
    png: {"png", "image/png"},
    webp: {"webp", "image/webp"},
    avif: {"avif", "image/avif"},
    heif: {"heic", "image/heif"},
    tiff: {"tiff", "image/tiff"},
    jpeg2000: {"jp2", "image/jp2"},
    jpeg_xl: {"jxl", "image/jxl"}
  }

  @spec render(SourceInfo.t()) :: {content_type :: String.t(), body :: iodata()}
  def render(%SourceInfo{} = info) do
    {format, mime} = wire(info.format)
    {w, h} = SourceInfo.display_dimensions(info)

    doc =
      %{
        "format" => format,
        "mime_type" => mime,
        "width" => w,
        "height" => h,
        "orientation" => info.orientation
      }
      |> maybe_put("size", info.byte_size)

    {"application/json", JSON.encode_to_iodata!(doc)}
  end

  defp wire(format),
    do: Map.get(@wire, format, {Atom.to_string(format), "application/octet-stream"})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

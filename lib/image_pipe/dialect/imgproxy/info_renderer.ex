defmodule ImagePipe.Dialect.Imgproxy.InfoRenderer do
  @moduledoc """
  Serializes `ImagePipe.Plan.SourceInfo` into imgproxy's /info JSON (header
  field set: format, mime_type, width, height, orientation, size). Owns imgproxy's
  wire spellings (per imgproxy `imagetype/defs.go`): HEIC is `"heic"`/`image/heif`,
  JPEG-XL is `"jxl"`/`image/jxl`; imgproxy has no `"heif"`/`"jpeg2000"` types. JP2 is
  a deliberate divergence (ImagePipe decodes it; imgproxy cannot). `width`/`height`
  are orientation-adjusted (swapped for EXIF 5-8).

  Receives decoded source header facts and returns the JSON response body.
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

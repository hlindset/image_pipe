defmodule ImagePipe.Decode.SourceFormat do
  @moduledoc false

  # Loader-name -> source-format classification for the decode bracket.

  alias Vix.Vips.Image, as: VipsImage

  @heif_family [:avif, :heif]

  @type source_format() :: ImagePipe.Format.source_format()
  @type unsupported_family() :: :bmp | :ico | :svg | :unknown
  @type error() :: {:unsupported_source_format, unsupported_family()}

  @doc """
  Checks that the loader libvips chose belongs to the `detected` family.

  AVIF and HEIF share one loader, so either detection accepts either codec and
  returns the one libvips reports.
  """
  @spec verify(VipsImage.t(), source_format()) ::
          {:ok, source_format()}
          | {:error, {:unsupported_source_format, source_format(), String.t() | nil}}
  def verify(image, detected) do
    loader =
      case header_value(image, "vips-loader") do
        {:ok, loader} -> loader
        :error -> nil
      end

    case classify_loader(loader, &header_value(image, &1)) do
      {:ok, format} when format == detected -> {:ok, format}
      {:ok, format} when format in @heif_family and detected in @heif_family -> {:ok, format}
      _other -> {:error, {:unsupported_source_format, detected, loader}}
    end
  end

  @spec from_image(VipsImage.t()) :: {:ok, source_format()} | {:error, error()}
  def from_image(image) do
    case header_value(image, "vips-loader") do
      {:ok, loader} -> classify_loader(loader, &header_value(image, &1))
      :error -> unsupported(:unknown)
    end
  end

  @spec classify_loader(term(), (String.t() -> {:ok, term()} | :error)) ::
          {:ok, source_format()} | {:error, error()}
  def classify_loader("jpegload" <> _suffix, _metadata), do: {:ok, :jpeg}
  def classify_loader("uhdrload" <> _suffix, _metadata), do: {:ok, :jpeg}
  def classify_loader("pngload" <> _suffix, _metadata), do: {:ok, :png}
  def classify_loader("webpload" <> _suffix, _metadata), do: {:ok, :webp}
  def classify_loader("tiffload" <> _suffix, _metadata), do: {:ok, :tiff}
  def classify_loader("jp2kload" <> _suffix, _metadata), do: {:ok, :jpeg2000}
  def classify_loader("jxlload" <> _suffix, _metadata), do: {:ok, :jpeg_xl}
  def classify_loader("gifload" <> _suffix, _metadata), do: {:ok, :gif}
  def classify_loader("heifload" <> _suffix, metadata), do: heif_format(metadata)
  def classify_loader("svgload" <> _suffix, _metadata), do: unsupported(:svg)
  def classify_loader(loader, _metadata) when is_binary(loader), do: unsupported(:unknown)
  def classify_loader(_loader, _metadata), do: unsupported(:unknown)

  defp header_value(image, name) do
    case VipsImage.header_value(image, name) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp heif_format(metadata) do
    case metadata.("heif-compression") do
      {:ok, "av1"} -> {:ok, :avif}
      _other -> {:ok, :heif}
    end
  end

  defp unsupported(family), do: {:error, {:unsupported_source_format, family}}
end

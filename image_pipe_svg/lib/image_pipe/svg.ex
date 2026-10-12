defmodule ImagePipe.SVG do
  @moduledoc """
  SVG support for ImagePipe.

  `image_pipe` calls this package when it is installed. It has no API meant
  for direct use.

  Rendering never reads a file or opens a connection: external references
  render as nothing, and text renders only with the fonts passed to
  `load_fonts/2`.
  """

  alias ImagePipe.SVG.{Document, Fonts, Native}

  @font_extensions ~w(.ttf .otf .ttc .otc)

  @type parse_error ::
          {:parse, String.t()}
          | {:too_many_elements, non_neg_integer()}
          | {:entity_expansion, non_neg_integer()}
          | {:too_much_text, non_neg_integer()}
          | {:image_too_large, non_neg_integer()}
          | :nesting_too_deep

  @type cost :: %{
          work: non_neg_integer(),
          peak: non_neg_integer(),
          images: non_neg_integer(),
          image_pixels: non_neg_integer()
        }

  @doc """
  Returns the versions of this package's NIF and the resvg it was built with.

  ImagePipe puts them in the cache key, since a new resvg can render the same
  SVG differently.
  """
  @spec versions() :: %{nif: String.t(), resvg: String.t()}
  def versions do
    {nif, resvg} = Native.versions()
    %{nif: nif, resvg: resvg}
  end

  @doc """
  Loads the TrueType and OpenType files (`.ttf`, `.otf`, `.ttc`, `.otc`)
  under `dirs`, searched recursively. System fonts are never loaded.

  Text in a font family that isn't loaded, and text in a generic family such
  as `sans-serif`, renders in the `:fallback_family`. Without one, that text
  is left out.

  Fails when a directory doesn't exist, when a font file can't be read or
  parsed, or when the fallback family
  isn't among the loaded fonts.
  """
  @spec load_fonts([Path.t()], keyword()) :: {:ok, Fonts.t()} | {:error, String.t()}
  def load_fonts(dirs, opts \\ []) when is_list(dirs) do
    with {:ok, files} <- read_fonts(dirs),
         {:ok, ref} <- Native.load_fonts(files, Keyword.get(opts, :fallback_family)) do
      {:ok, %Fonts{ref: ref, fingerprint: fingerprint(files)}}
    end
  end

  defp read_fonts(dirs) do
    case Enum.reject(dirs, &File.dir?/1) do
      [] -> read_font_files(dirs)
      [dir | _] -> {:error, "#{dir} isn't a directory"}
    end
  end

  defp read_font_files(dirs) do
    dirs
    |> Enum.flat_map(fn dir -> Enum.map(font_paths(dir), &{dir, &1}) end)
    |> Enum.reduce_while({:ok, []}, fn {dir, path}, {:ok, files} ->
      case File.read(path) do
        {:ok, data} -> {:cont, {:ok, [{Path.relative_to(path, dir), data} | files]}}
        {:error, reason} -> {:halt, {:error, "can't read #{path}: #{:file.format_error(reason)}"}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.sort(files)}
      error -> error
    end
  end

  defp font_paths(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in @font_extensions))
  end

  defp fingerprint(files) do
    files
    |> Enum.reduce(:crypto.hash_init(:sha256), fn {name, data}, hash ->
      hash
      |> :crypto.hash_update(<<byte_size(name)::32, name::binary>>)
      |> :crypto.hash_update(<<byte_size(data)::64, data::binary>>)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Parses an SVG.

  Embedded `data:` images load only as PNG, JPEG, GIF, WebP, or SVG whose
  declared media type matches their contents. Others, and gzip-compressed
  SVG, render as empty. Embedded SVGs nest at most two levels deep.

  ## Options

    * `:max_elements` - elements allowed after expanding `<use>`, checked
      before expanding them. Defaults to 200,000.
    * `:max_image_pixels` - pixels allowed in any one embedded raster
      image, read from its header. Defaults to 40,000,000.
    * `:max_entity_expansion` - characters the document's entity references
      may expand to, estimated before parsing. A few kilobytes of entity
      declarations can otherwise expand to hundreds of megabytes. Defaults to
      1,000,000.
    * `:max_text_per_element` - bytes of text in any one `<text>` element,
      including its `<tspan>`s. Text is laid out while parsing, at a cost
      that grows with the square of one element's text. Defaults to 10,000.
    * `:max_text` - bytes of text in all `<text>` elements, counting each
      `<use>` copy. Defaults to 1,000,000.

  The limits apply to embedded SVGs too.
  """
  @spec parse(binary(), Fonts.t(), keyword()) :: {:ok, Document.t()} | {:error, parse_error()}
  def parse(data, %Fonts{ref: fonts}, opts \\ []) when is_binary(data) do
    limits = {
      Keyword.get(opts, :max_elements, 200_000),
      Keyword.get(opts, :max_image_pixels, 40_000_000),
      Keyword.get(opts, :max_entity_expansion, 1_000_000),
      Keyword.get(opts, :max_text_per_element, 10_000),
      Keyword.get(opts, :max_text, 1_000_000)
    }

    with {:ok, {ref, width, height}} <- Native.parse(data, fonts, limits) do
      {:ok, %Document{ref: ref, width: width, height: height}}
    end
  end

  @doc """
  Estimates what rendering `document` at `width` × `height` costs, without
  rendering it.

  `work` counts pixels pushed through offscreen pixmaps, weighted by how
  slowly each kind of pixmap work runs. `peak` is the most pixmap pixels
  alive at once, including the output. `images` and `image_pixels` count
  embedded raster image draws and the pixels they decode.
  """
  @spec cost(Document.t(), pos_integer(), pos_integer()) :: cost()
  def cost(%Document{ref: ref}, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    {work, peak, images, image_pixels} = Native.cost(ref, width, height)
    %{work: work, peak: peak, images: images, image_pixels: image_pixels}
  end

  @doc """
  Renders `document` scaled to `width` × `height`, returning 8-bit
  straight-alpha RGBA pixels, row by row.
  """
  @spec render(Document.t(), pos_integer(), pos_integer()) :: binary()
  def render(%Document{ref: ref}, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    Native.render(ref, width, height)
  end
end

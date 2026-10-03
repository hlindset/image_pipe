defmodule ImagePipe.Result do
  @moduledoc """
  The complete output of `ImagePipe.run/4` or `ImagePipe.write/5`.

      {:ok, result} = ImagePipe.run(config, builder, {:file, "photos/cat.jpg"})
      {result.format, result.width, result.height}
      #=> {:webp, 400, 300}

  A result holds no open file, source, or image. Its fields depend on the
  plan's `terminal` output option:

  | `terminal` | `data` | `content_type` | Also set |
  | --- | --- | --- | --- |
  | `:image` | Encoded image bytes | The image's MIME type, such as `"image/webp"` | `format`, `width`, `height` |
  | `:blurhash` | BlurHash string | `"text/plain"` | |
  | `:lqip_css` | CSS color string, such as `"#47a8f53d"` | `"text/plain"` | |
  | `:info` | Map with string keys | `"application/json"` | |

  `format` can be a format ImagePipe only reads, such as `:gif`, when the
  configuration's `:skip_processing_formats` returns the original unchanged.

  An `:info` result has `terminal: :info`, also for a plan with
  `terminal: {:info, [:blurhash]}`. Its map has two keys:

    * `"source"` - the original's `"format"`, `"mime_type"`, `"width"`,
      `"height"`, `"orientation"` (the EXIF value), `"pages"`, and `"size"`
      in bytes when known. Width and height are as displayed, after EXIF
      orientation.
    * `"result"` - the output's `"width"`, `"height"`, and `"dpr"`, plus
      `"blurhash"` and `"lqip_css"` when requested.

  `degraded?` is `true` when a `detect` crop fell back to attention-based
  cropping because detection failed. Such a result isn't stored in the
  cache, and retrying later may give the detected crop.
  """

  @enforce_keys [:terminal, :data, :content_type]
  defstruct @enforce_keys ++ [format: nil, width: nil, height: nil, degraded?: false]

  @type t :: %__MODULE__{
          terminal: :image | :info | :blurhash | :lqip_css,
          data: binary() | map(),
          content_type: String.t(),
          format: ImagePipe.Format.source_format() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil,
          degraded?: boolean()
        }
end

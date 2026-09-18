defmodule ImagePipe.Native.OptionSpec do
  @moduledoc """
  Declarative option table for the ImagePipe URL API.

  Each `%OptionSpec{}` defines an option's key, scope, value parser, conflicts,
  and supported outputs. `ImagePipe.Native.Parser` handles resize intent,
  guide consumers, and group assembly.

  Tests require complete entries with at least one example each.
  """

  alias ImagePipe.Native.OutputOptions
  alias ImagePipe.Native.Value

  @enforce_keys [
    :key,
    :scope,
    :value,
    :stage,
    :default,
    :prerequisites,
    :conflicts,
    :identity,
    :terminal_applicability,
    :summary,
    :examples
  ]
  defstruct @enforce_keys

  @type value_parser :: (String.t() -> {:ok, term()} | {:error, atom()})
  @type length_value :: {:px, number()} | {:pct, number()}
  @type color_value :: {0..255, 0..255, 0..255}

  @type t :: %__MODULE__{
          key: String.t(),
          scope: :group | :request,
          value: :flag | value_parser(),
          stage: pos_integer() | nil,
          default: term(),
          # Describes dependencies; Parser.tier2_group_errors/3 validates them.
          prerequisites: [atom()],
          conflicts: [String.t()],
          identity: :representation | :storage | :gate | :presentation,
          terminal_applicability: :pixels | :image | :all,
          summary: String.t(),
          examples: [String.t()]
        }

  @fit_map %{
    "contain" => :contain,
    "cover" => :cover,
    "cover-down" => :cover_down,
    "stretch" => :stretch,
    "auto" => :auto
  }

  @anchor_map %{
    "center" => :center,
    "top" => :top,
    "bottom" => :bottom,
    "left" => :left,
    "right" => :right,
    "top-left" => :top_left,
    "top-right" => :top_right,
    "bottom-left" => :bottom_left,
    "bottom-right" => :bottom_right,
    "smart" => :smart,
    "smart-face" => :smart_face
  }

  @format_map %{
    "avif" => :avif,
    "webp" => :webp,
    "jpeg" => :jpeg,
    "png" => :png,
    "jxl" => :jpeg_xl
  }

  @output_map %{
    "image" => :image,
    "blurhash" => :blurhash,
    "info" => :info
  }

  @metadata_map %{
    "strip" => :strip,
    "copyright" => :copyright,
    "keep" => :keep
  }

  @color_profile_map %{
    "strip" => :strip,
    "preserve" => :preserve_source,
    "srgb" => {:convert, :srgb},
    "display-p3" => {:convert, :display_p3},
    "adobe-rgb" => {:convert, :adobe_rgb}
  }

  @hdr_map %{
    "tonemap" => :tone_map,
    "preserve" => :preserve
  }

  @preset_name_pattern ~r/\A[A-Za-z0-9._-]+\z/
  @path_token_pattern ~r/\A[A-Za-z0-9._-]+\z/
  @positive_decimal_pattern ~r/\A[0-9]+(?:\.[0-9]+)?\z/
  @unsigned_integer_pattern ~r/\A[0-9]+\z/
  @signed_integer_pattern ~r/\A-?[0-9]+\z/
  @detect_class_pattern ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @max_vips_axis 2_147_483_647
  @max_detect_weight 1_000_000.0
  @default_monochrome_color {179, 179, 179}
  @gradient_directions %{
    "down" => 0.0,
    "left" => 90.0,
    "up" => 180.0,
    "right" => 270.0
  }

  @doc """
  Returns every declared option in a stable order.
  """
  @spec all() :: [t()]
  def all do
    [
      %__MODULE__{
        key: "rotate",
        scope: :group,
        value: &__MODULE__.parse_rotate/1,
        stage: 1,
        default: 0,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Clockwise rotation in degrees from 0 to 360",
        examples: ["rotate=30", "rotate=90"]
      },
      %__MODULE__{
        key: "flip",
        scope: :group,
        value: &__MODULE__.parse_flip/1,
        stage: 2,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Flip horizontally, vertically, or both after rotation",
        examples: ["flip=h", "flip=v", "flip=hv"]
      },
      %__MODULE__{
        key: "gray",
        scope: :group,
        value: :flag,
        stage: 10,
        default: false,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Convert to grayscale",
        examples: ["gray"]
      },
      %__MODULE__{
        key: "bitonal",
        scope: :group,
        value: :flag,
        stage: 11,
        default: false,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Threshold grayscale at 128 to black and white, preserving alpha",
        examples: ["bitonal"]
      },
      %__MODULE__{
        key: "dpr",
        scope: :group,
        value: &__MODULE__.parse_dpr/1,
        stage: 5,
        default: 1.0,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Device pixel ratio multiplier",
        examples: ["dpr=2", "dpr=1.5"]
      },
      %__MODULE__{
        key: "w",
        scope: :group,
        value: &__MODULE__.parse_dimension/1,
        stage: 5,
        default: :auto,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Resize target width, in px, or auto to preserve aspect",
        examples: ["w=800"]
      },
      %__MODULE__{
        key: "h",
        scope: :group,
        value: &__MODULE__.parse_dimension/1,
        stage: 5,
        default: :auto,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Resize target height, in px, or auto to preserve aspect",
        examples: ["h=400"]
      },
      %__MODULE__{
        key: "min-w",
        scope: :group,
        value: &__MODULE__.parse_min_dimension/1,
        stage: 5,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Minimum resize width in pixels",
        examples: ["min-w=320"]
      },
      %__MODULE__{
        key: "min-h",
        scope: :group,
        value: &__MODULE__.parse_min_dimension/1,
        stage: 5,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Minimum resize height in pixels",
        examples: ["min-h=240"]
      },
      %__MODULE__{
        key: "fit",
        scope: :group,
        value: &__MODULE__.parse_fit/1,
        stage: 5,
        default: :contain,
        prerequisites: [:resize_intent],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Resize mode: contain, cover, cover-down, stretch, or auto",
        examples: ["fit=cover"]
      },
      %__MODULE__{
        key: "enlarge",
        scope: :group,
        value: :flag,
        stage: 5,
        default: false,
        prerequisites: [:resize_intent],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Allow the resize to upscale past source dimensions",
        examples: ["enlarge"]
      },
      %__MODULE__{
        key: "zoom",
        scope: :group,
        value: &__MODULE__.parse_zoom/1,
        stage: 5,
        default: {1.0, 1.0},
        prerequisites: [:resize_intent],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Positive resize multiplier as one scalar or x,y pair",
        examples: ["zoom=2", "zoom=1.25,0.75"]
      },
      %__MODULE__{
        key: "extend",
        scope: :group,
        value: :flag,
        stage: 19,
        default: false,
        prerequisites: [:concrete_box],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Extend to the requested width and height",
        examples: ["extend"]
      },
      %__MODULE__{
        key: "extend-ratio",
        scope: :group,
        value: :flag,
        stage: 19,
        default: false,
        prerequisites: [:concrete_box],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Extend to the requested width-to-height ratio",
        examples: ["extend-ratio"]
      },
      %__MODULE__{
        key: "extend-at",
        scope: :group,
        value: &__MODULE__.parse_named_anchor/1,
        stage: 19,
        default: :center,
        prerequisites: [:canvas],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Canvas placement anchor",
        examples: ["extend-at=bottom-right"]
      },
      %__MODULE__{
        key: "extend-offset",
        scope: :group,
        value: &__MODULE__.parse_offset/1,
        stage: 19,
        default: {{:px, 0}, {:px, 0}},
        prerequisites: [:canvas],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Signed x,y canvas placement offset",
        examples: ["extend-offset=10,-20pct"]
      },
      %__MODULE__{
        key: "crop",
        scope: :group,
        value: &__MODULE__.parse_crop/1,
        stage: 4,
        default: nil,
        prerequisites: [],
        conflicts: ["region"],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Guided crop to w,h (px or pct), guided by anchor/focus",
        examples: ["crop=600,400"]
      },
      %__MODULE__{
        key: "crop-ratio",
        scope: :group,
        value: &__MODULE__.parse_crop_ratio/1,
        stage: 4,
        default: nil,
        prerequisites: [:crop],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Crop aspect ratio as a:b or a positive decimal",
        examples: ["crop-ratio=3:2", "crop-ratio=1.5"]
      },
      %__MODULE__{
        key: "crop-ratio-enlarge",
        scope: :group,
        value: :flag,
        stage: 4,
        default: false,
        prerequisites: [:crop_ratio],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Allow crop ratio correction to enlarge the crop box",
        examples: ["crop-ratio-enlarge"]
      },
      %__MODULE__{
        key: "region",
        scope: :group,
        value: &__MODULE__.parse_region/1,
        stage: 4,
        default: nil,
        prerequisites: [],
        conflicts: ["crop"],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Explicit-region crop x,y,w,h (px or pct)",
        examples: ["region=0,0,600,400"]
      },
      %__MODULE__{
        key: "anchor",
        scope: :group,
        value: &__MODULE__.parse_anchor/1,
        stage: 6,
        default: :center,
        prerequisites: [:guide_consumer],
        conflicts: ["detect", "focus"],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Crop guide / gravity for a guided crop or cover-family resize",
        examples: ["anchor=smart"]
      },
      %__MODULE__{
        key: "anchor-offset",
        scope: :group,
        value: &__MODULE__.parse_offset/1,
        stage: 6,
        default: nil,
        prerequisites: [:named_anchor],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Signed x,y offset from a named crop anchor",
        examples: ["anchor-offset=10,-20pct"]
      },
      %__MODULE__{
        key: "focus",
        scope: :group,
        value: &__MODULE__.parse_focus/1,
        stage: 6,
        default: nil,
        prerequisites: [:guide_consumer],
        conflicts: ["anchor", "detect"],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Focal point as x,y unit-space fractions (0.0-1.0)",
        examples: ["focus=0.25,0.75"]
      },
      %__MODULE__{
        key: "detect",
        scope: :group,
        value: &__MODULE__.parse_detect/1,
        stage: 6,
        default: nil,
        prerequisites: [:guide_consumer],
        conflicts: ["anchor", "focus"],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Detector classes with optional positive class weights",
        examples: ["detect=all", "detect=car,face", "detect=all:1,face:3"]
      },
      %__MODULE__{
        key: "blur",
        scope: :group,
        value: &__MODULE__.parse_blur/1,
        stage: 7,
        default: 0.0,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Gaussian blur sigma; 0 is the Tier-1 identity point",
        examples: ["blur=2.5"]
      },
      %__MODULE__{
        key: "sharpen",
        scope: :group,
        value: &__MODULE__.parse_sharpen/1,
        stage: 8,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Sharpen sigma; 0 is the identity point",
        examples: ["sharpen=1.5"]
      },
      %__MODULE__{
        key: "pixelate",
        scope: :group,
        value: &__MODULE__.parse_pixelate/1,
        stage: 9,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Pixelation block size; 1 is the identity point",
        examples: ["pixelate=8"]
      },
      %__MODULE__{
        key: "monochrome",
        scope: :group,
        value: &__MODULE__.parse_monochrome/1,
        stage: 12,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Monochrome intensity and optional color",
        examples: ["monochrome=0.5", "monochrome=1,red"]
      },
      %__MODULE__{
        key: "duotone",
        scope: :group,
        value: &__MODULE__.parse_duotone/1,
        stage: 13,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Duotone intensity with optional shadow and highlight colors",
        examples: ["duotone=0.5", "duotone=1,112233,ffeecc"]
      },
      %__MODULE__{
        key: "brightness",
        scope: :group,
        value: &__MODULE__.parse_brightness/1,
        stage: 14,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Additive brightness adjustment from -255 to 255",
        examples: ["brightness=-20"]
      },
      %__MODULE__{
        key: "contrast",
        scope: :group,
        value: &__MODULE__.parse_contrast/1,
        stage: 15,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Positive contrast factor; 1 is the identity point",
        examples: ["contrast=1.25"]
      },
      %__MODULE__{
        key: "saturation",
        scope: :group,
        value: &__MODULE__.parse_saturation/1,
        stage: 16,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Positive saturation factor; 1 is the identity point",
        examples: ["saturation=0.5"]
      },
      %__MODULE__{
        key: "colorize",
        scope: :group,
        value: &__MODULE__.parse_colorize/1,
        stage: 17,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Color overlay with optional alpha preservation",
        examples: ["colorize=0.5,red", "colorize=1,ff0000,keep-alpha"]
      },
      %__MODULE__{
        key: "gradient",
        scope: :group,
        value: &__MODULE__.parse_gradient/1,
        stage: 18,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Directional color gradient with unit-space stops",
        examples: ["gradient=1,red,left,0.25,0.75"]
      },
      %__MODULE__{
        key: "trim",
        scope: :group,
        value: &__MODULE__.parse_trim/1,
        stage: 3,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Trim a surrounding background: auto, or color[,tolerance]",
        examples: ["trim=auto", "trim=fff,10"]
      },
      %__MODULE__{
        key: "trim-symmetry",
        scope: :group,
        value: &__MODULE__.parse_trim_symmetry/1,
        stage: 3,
        default: nil,
        prerequisites: [:trim],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Make trim margins symmetric horizontally, vertically, or on both axes",
        examples: ["trim-symmetry=h", "trim-symmetry=v", "trim-symmetry=hv"]
      },
      %__MODULE__{
        key: "pad",
        scope: :group,
        value: &Value.pad_shorthand/1,
        stage: 20,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "CSS 1-4 value px shorthand padding",
        examples: ["pad=20", "pad=10,20,30,40"]
      },
      %__MODULE__{
        key: "bg",
        scope: :group,
        value: &__MODULE__.parse_bg/1,
        stage: 21,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Background color, flattens transparency: color[,alpha]",
        examples: ["bg=f4f4f4"]
      },
      %__MODULE__{
        key: "orient",
        scope: :request,
        value: &__MODULE__.parse_orientation/1,
        stage: nil,
        default: :auto,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :pixels,
        summary: "Apply EXIF orientation automatically, or ignore it",
        examples: ["orient=auto", "orient=none"]
      },
      %__MODULE__{
        key: "output",
        scope: :request,
        value: &__MODULE__.parse_output/1,
        stage: nil,
        default: :image,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :all,
        summary: "Terminal selection: image (default), blurhash, or info",
        examples: ["output=blurhash", "output=info"]
      },
      %__MODULE__{
        key: "format",
        scope: :request,
        value: &__MODULE__.parse_format/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Explicit output image format; absent negotiates via Accept",
        examples: ["format=webp"]
      },
      %__MODULE__{
        key: "q",
        scope: :request,
        value: &__MODULE__.parse_quality/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Output quality, 1-100",
        examples: ["q=80"]
      },
      %__MODULE__{
        key: "format-q",
        scope: :request,
        value: &__MODULE__.parse_format_qualities/1,
        stage: nil,
        default: %{},
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Per-format output quality overrides",
        examples: ["format-q=avif:60,webp:70"]
      },
      %__MODULE__{
        key: "meta",
        scope: :request,
        value: &__MODULE__.parse_metadata/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Output metadata retention policy",
        examples: ["meta=strip", "meta=copyright", "meta=keep"]
      },
      %__MODULE__{
        key: "profile",
        scope: :request,
        value: &__MODULE__.parse_color_profile/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Output color profile policy",
        examples: ["profile=preserve", "profile=display-p3"]
      },
      %__MODULE__{
        key: "hdr",
        scope: :request,
        value: &__MODULE__.parse_hdr/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Output HDR policy",
        examples: ["hdr=tonemap", "hdr=preserve"]
      },
      %__MODULE__{
        key: "autoquality",
        scope: :request,
        value: &__MODULE__.parse_autoquality/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Adaptive quality method with optional named controls",
        examples: ["autoquality=ssimulacra2,target:78,error:2", "autoquality=none"]
      },
      %__MODULE__{
        key: "max-bytes",
        scope: :request,
        value: &__MODULE__.parse_max_bytes/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Positive encoded byte budget",
        examples: ["max-bytes=12000"]
      },
      %__MODULE__{
        key: "jpeg-options",
        scope: :request,
        value: &__MODULE__.parse_jpeg_options/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Sparse JPEG encoder options",
        examples: ["jpeg-options=progressive,quant-table:3"]
      },
      %__MODULE__{
        key: "png-options",
        scope: :request,
        value: &__MODULE__.parse_png_options/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Sparse PNG encoder options",
        examples: ["png-options=palette,filter:paeth"]
      },
      %__MODULE__{
        key: "webp-options",
        scope: :request,
        value: &__MODULE__.parse_webp_options/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Sparse WebP encoder options",
        examples: ["webp-options=near-lossless,effort:6"]
      },
      %__MODULE__{
        key: "avif-options",
        scope: :request,
        value: &__MODULE__.parse_avif_options/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Sparse AVIF encoder options",
        examples: ["avif-options=subsample:on,effort:6"]
      },
      %__MODULE__{
        key: "jxl-options",
        scope: :request,
        value: &__MODULE__.parse_jxl_options/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :representation,
        terminal_applicability: :image,
        summary: "Sparse JPEG XL encoder options",
        examples: ["jxl-options=effort:4"]
      },
      %__MODULE__{
        key: "filename",
        scope: :request,
        value: &__MODULE__.parse_filename/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :presentation,
        terminal_applicability: :all,
        summary: "ASCII filename stem for response delivery",
        examples: ["filename=card-v2"]
      },
      %__MODULE__{
        key: "attachment",
        scope: :request,
        value: :flag,
        stage: nil,
        default: false,
        prerequisites: [],
        conflicts: [],
        identity: :presentation,
        terminal_applicability: :all,
        summary: "Deliver the response as an attachment",
        examples: ["attachment"]
      },
      %__MODULE__{
        key: "cb",
        scope: :request,
        value: &__MODULE__.parse_cachebuster/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :storage,
        terminal_applicability: :all,
        summary: "ASCII storage cachebuster token",
        examples: ["cb=release-42"]
      },
      %__MODULE__{
        key: "debug",
        scope: :request,
        value: :flag,
        stage: nil,
        default: false,
        prerequisites: [],
        conflicts: [],
        identity: :presentation,
        terminal_applicability: :all,
        summary: "Request debug response headers when the mount allows them",
        examples: ["debug"]
      },
      %__MODULE__{
        key: "expires",
        scope: :request,
        value: &__MODULE__.parse_expires/1,
        stage: nil,
        default: nil,
        prerequisites: [],
        conflicts: [],
        identity: :gate,
        terminal_applicability: :all,
        summary: "Unix timestamp after which the URL is invalid (404)",
        examples: ["expires=1999999999"]
      },
      %__MODULE__{
        key: "preset",
        scope: :request,
        value: &__MODULE__.parse_preset_names/1,
        stage: nil,
        default: [],
        prerequisites: [],
        conflicts: [],
        identity: :gate,
        terminal_applicability: :all,
        summary: "One or more configured preset names to expand",
        examples: ["preset=card"]
      }
    ]
  end

  @doc """
  Looks up a declared option by its URL key string, `nil` when unknown.
  """
  @spec fetch(String.t()) :: t() | nil
  def fetch(key) when is_binary(key) do
    Enum.find(all(), &(&1.key == key))
  end

  # -- per-key value parsers -------------------------------------------
  #
  # Each parses one segment's value shape. The parser combines options and
  # supplies defaults, such as an omitted trim tolerance.

  @doc false
  @spec parse_dpr(String.t()) :: {:ok, float()} | {:error, :invalid_dpr}
  def parse_dpr(string) do
    case positive_decimal(string) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_dpr}
    end
  end

  @doc false
  @spec parse_dimension(String.t()) ::
          {:ok, :auto | pos_integer()} | {:error, :invalid_dimension}
  def parse_dimension(string) do
    case Value.dimension(string) do
      {:ok, :auto} -> {:ok, :auto}
      {:ok, {:px, n}} -> {:ok, n}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_min_dimension(String.t()) ::
          {:ok, pos_integer()} | {:error, :invalid_min_dimension}
  def parse_min_dimension(string) do
    case Value.dimension(string) do
      {:ok, {:px, n}} -> {:ok, n}
      _invalid -> {:error, :invalid_min_dimension}
    end
  end

  @doc false
  @spec parse_zoom(String.t()) ::
          {:ok, {float(), float()}} | {:error, :invalid_zoom}
  def parse_zoom(string) do
    case String.split(string, ",") do
      [scalar] ->
        case positive_decimal(scalar) do
          {:ok, value} -> {:ok, {value, value}}
          :error -> {:error, :invalid_zoom}
        end

      [x, y] ->
        with {:ok, x} <- positive_decimal(x),
             {:ok, y} <- positive_decimal(y) do
          {:ok, {x, y}}
        else
          :error -> {:error, :invalid_zoom}
        end

      _invalid_arity ->
        {:error, :invalid_zoom}
    end
  end

  defp positive_decimal(string) do
    if Regex.match?(@positive_decimal_pattern, string) do
      case Float.parse(string) do
        {value, ""} when value > 0.0 -> {:ok, value}
        _zero_or_out_of_float_range -> :error
      end
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc false
  @spec parse_fit(String.t()) ::
          {:ok, :contain | :cover | :cover_down | :stretch | :auto} | {:error, :invalid_fit}
  def parse_fit(string) do
    case Map.fetch(@fit_map, string) do
      {:ok, fit} -> {:ok, fit}
      :error -> {:error, :invalid_fit}
    end
  end

  @doc false
  @spec parse_crop(String.t()) :: {:ok, {length_value(), length_value()}} | {:error, atom()}
  def parse_crop(string) do
    case Value.csv(string, 2..2, [&positive_length/1, &positive_length/1]) do
      {:ok, [w, h]} -> {:ok, {w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_crop_ratio(String.t()) ::
          {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, :invalid_crop_ratio}
  def parse_crop_ratio(string) do
    result =
      case String.split(string, ":") do
        [decimal] -> decimal_ratio(decimal)
        [numerator, denominator] -> integer_ratio(numerator, denominator)
        _invalid_arity -> :error
      end

    case result do
      {:ok, {numerator, denominator}} ->
        ratio = normalized_ratio(numerator, denominator)

        if pixel_geometry_ratio?(ratio) do
          {:ok, ratio}
        else
          {:error, :invalid_crop_ratio}
        end

      :error ->
        {:error, :invalid_crop_ratio}
    end
  end

  defp decimal_ratio(string) do
    if Regex.match?(@positive_decimal_pattern, string) do
      case String.split(string, ".", parts: 2) do
        [integer] ->
          positive_ratio_parts(String.to_integer(integer), 1)

        [integer, fraction] ->
          denominator = Integer.pow(10, String.length(fraction))
          numerator = String.to_integer(integer) * denominator + String.to_integer(fraction)
          positive_ratio_parts(numerator, denominator)
      end
    else
      :error
    end
  end

  defp integer_ratio(numerator, denominator) do
    with true <- Regex.match?(@unsigned_integer_pattern, numerator),
         true <- Regex.match?(@unsigned_integer_pattern, denominator),
         {numerator, ""} <- Integer.parse(numerator),
         {denominator, ""} <- Integer.parse(denominator) do
      positive_ratio_parts(numerator, denominator)
    else
      _invalid -> :error
    end
  end

  defp positive_ratio_parts(numerator, denominator)
       when numerator > 0 and denominator > 0,
       do: {:ok, {numerator, denominator}}

  defp positive_ratio_parts(_numerator, _denominator), do: :error

  defp normalized_ratio(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)
    {:ratio, div(numerator, gcd), div(denominator, gcd)}
  end

  # Crop geometry may multiply either direction of the ratio by a libvips
  # image axis. Reject public numeric input unless both directions survive
  # that arithmetic as positive finite BEAM floats. Integer-to-float
  # conversion and float overflow raise `ArithmeticError`; this rescue is
  # intentionally limited to the request numeric boundary.
  defp pixel_geometry_ratio?({:ratio, numerator, denominator}) do
    ratio = numerator / denominator
    reciprocal = denominator / numerator

    ratio > 0.0 and reciprocal > 0.0 and
      ratio * @max_vips_axis > 0.0 and reciprocal * @max_vips_axis > 0.0
  rescue
    ArithmeticError -> false
  end

  @doc false
  @spec parse_region(String.t()) ::
          {:ok, {length_value(), length_value(), length_value(), length_value()}}
          | {:error, atom()}
  def parse_region(string) do
    case Value.csv(string, 4..4, [
           &Value.length/1,
           &Value.length/1,
           &positive_length/1,
           &positive_length/1
         ]) do
      {:ok, [x, y, w, h]} -> {:ok, {x, y, w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp positive_length(string) do
    case Value.length(string) do
      {:ok, {_unit, value} = length} when value > 0 -> {:ok, length}
      _invalid -> {:error, :invalid_length}
    end
  end

  @doc false
  @spec parse_anchor(String.t()) ::
          {:ok,
           :center
           | :top
           | :bottom
           | :left
           | :right
           | :top_left
           | :top_right
           | :bottom_left
           | :bottom_right
           | :smart
           | :smart_face}
          | {:error, :invalid_anchor}
  def parse_anchor(string) do
    case Map.fetch(@anchor_map, string) do
      {:ok, anchor} -> {:ok, anchor}
      :error -> {:error, :invalid_anchor}
    end
  end

  @doc false
  @spec parse_named_anchor(String.t()) :: {:ok, atom()} | {:error, :invalid_anchor}
  def parse_named_anchor(string) do
    case parse_anchor(string) do
      {:ok, smart} when smart in [:smart, :smart_face] -> {:error, :invalid_anchor}
      result -> result
    end
  end

  @doc false
  @spec parse_detect(String.t()) ::
          {:ok, {:all | [String.t()], %{optional(:default | String.t()) => float()}}}
          | {:error, :invalid_detect}
  def parse_detect(string) do
    with {:ok, pairs} <- parse_detect_items(String.split(string, ",")),
         true <- unique_detect_classes?(pairs) do
      {:ok, canonical_detect(pairs)}
    else
      _invalid -> {:error, :invalid_detect}
    end
  end

  defp parse_detect_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case parse_detect_item(String.split(item, ":")) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp parse_detect_item([class]) do
    if valid_detect_class?(class), do: {:ok, {class, 1.0}}, else: :error
  end

  defp parse_detect_item([class, weight]) do
    with true <- valid_detect_class?(class),
         {:ok, weight} <- positive_decimal(weight),
         true <- weight <= @max_detect_weight do
      {:ok, {class, weight}}
    else
      _invalid -> :error
    end
  end

  defp parse_detect_item(_invalid), do: :error

  defp valid_detect_class?(class), do: Regex.match?(@detect_class_pattern, class)

  defp unique_detect_classes?(pairs) do
    classes = Enum.map(pairs, &elem(&1, 0))
    Enum.uniq(classes) == classes
  end

  defp canonical_detect(pairs) do
    classes = pairs |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    spec = if "all" in classes, do: :all, else: classes
    {spec, canonical_detect_weights(pairs)}
  end

  defp canonical_detect_weights(pairs) do
    raw = Map.new(pairs, fn {class, weight} -> {detect_weight_key(class), weight} end)
    effective_default = Map.get(raw, :default, 1.0)

    raw
    |> Enum.reject(fn {key, weight} -> key != :default and weight == effective_default end)
    |> Map.new()
    |> drop_default_detect_weight()
  end

  defp detect_weight_key("all"), do: :default
  defp detect_weight_key(class), do: class

  defp drop_default_detect_weight(%{default: 1.0} = weights), do: Map.delete(weights, :default)
  defp drop_default_detect_weight(weights), do: weights

  @doc false
  @spec parse_offset(String.t()) ::
          {:ok, {length_value(), length_value()}} | {:error, :invalid_offset}
  def parse_offset(string) do
    case Value.csv(string, 2..2, [&safe_signed_length/1, &safe_signed_length/1]) do
      {:ok, [x, y]} -> {:ok, {x, y}}
      {:error, _reason} -> {:error, :invalid_offset}
    end
  rescue
    ArgumentError -> {:error, :invalid_offset}
    ArithmeticError -> {:error, :invalid_offset}
  end

  defp safe_signed_length(string) do
    case Value.length(string) do
      {:ok, {_unit, value} = length} ->
        _scaled_for_max_axis = abs(value * 1.0) * @max_vips_axis
        {:ok, length}

      {:error, _reason} ->
        {:error, :invalid_length}
    end
  end

  @doc false
  @spec parse_focus(String.t()) :: {:ok, {float(), float()}} | {:error, atom()}
  def parse_focus(string) do
    case Value.csv(string, 2..2, [&Value.fraction/1, &Value.fraction/1]) do
      {:ok, [fx, fy]} -> {:ok, {fx, fy}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_rotate(String.t()) :: {:ok, number()} | {:error, :invalid_rotation}
  def parse_rotate(string) do
    case Value.number(string) do
      {:ok, angle} when angle >= 0 and angle <= 360 ->
        angle = if angle == trunc(angle), do: rem(trunc(angle), 360), else: angle
        {:ok, angle}

      _invalid ->
        {:error, :invalid_rotation}
    end
  end

  @spec parse_flip(String.t()) ::
          {:ok, :horizontal | :vertical | :both} | {:error, :invalid_flip}
  def parse_flip("h"), do: {:ok, :horizontal}
  def parse_flip("v"), do: {:ok, :vertical}
  def parse_flip("hv"), do: {:ok, :both}
  def parse_flip(_value), do: {:error, :invalid_flip}

  @doc false
  @spec parse_blur(String.t()) :: {:ok, float()} | {:error, :invalid_blur}
  def parse_blur(string) do
    case nonnegative_float(string) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_blur}
    end
  end

  @doc false
  @spec parse_sharpen(String.t()) :: {:ok, float()} | {:error, :invalid_sharpen}
  def parse_sharpen(string) do
    case nonnegative_float(string) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_sharpen}
    end
  end

  @doc false
  @spec parse_pixelate(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_pixelate}
  def parse_pixelate(string) do
    if Regex.match?(@unsigned_integer_pattern, string) do
      case String.to_integer(string) do
        value when value >= 1 -> {:ok, value}
        _zero -> {:error, :invalid_pixelate}
      end
    else
      {:error, :invalid_pixelate}
    end
  end

  @doc false
  @spec parse_monochrome(String.t()) :: {:ok, map()} | {:error, :invalid_monochrome}
  def parse_monochrome(string) do
    result =
      case String.split(string, ",", trim: false) do
        [intensity] ->
          with {:ok, intensity} <- Value.fraction(intensity) do
            {:ok, %{intensity: intensity, color: @default_monochrome_color}}
          end

        [intensity, color] ->
          with {:ok, intensity} <- Value.fraction(intensity),
               {:ok, color} <- Value.color(color) do
            {:ok, %{intensity: intensity, color: color}}
          end

        _invalid_arity ->
          :error
      end

    effect_result(result, :invalid_monochrome)
  end

  @doc false
  @spec parse_duotone(String.t()) :: {:ok, map()} | {:error, :invalid_duotone}
  def parse_duotone(string) do
    result =
      case String.split(string, ",", trim: false) do
        [intensity] ->
          with {:ok, intensity} <- Value.fraction(intensity) do
            {:ok, %{intensity: intensity, shadow: {0, 0, 0}, highlight: {255, 255, 255}}}
          end

        [intensity, shadow, highlight] ->
          with {:ok, intensity} <- Value.fraction(intensity),
               {:ok, shadow} <- Value.color(shadow),
               {:ok, highlight} <- Value.color(highlight) do
            {:ok, %{intensity: intensity, shadow: shadow, highlight: highlight}}
          end

        _invalid_arity ->
          :error
      end

    effect_result(result, :invalid_duotone)
  end

  @doc false
  @spec parse_brightness(String.t()) :: {:ok, -255..255} | {:error, :invalid_brightness}
  def parse_brightness(string) do
    if Regex.match?(@signed_integer_pattern, string) do
      case String.to_integer(string) do
        value when value >= -255 and value <= 255 -> {:ok, value}
        _out_of_range -> {:error, :invalid_brightness}
      end
    else
      {:error, :invalid_brightness}
    end
  end

  @doc false
  @spec parse_contrast(String.t()) :: {:ok, float()} | {:error, :invalid_contrast}
  def parse_contrast(string), do: parse_factor(string, :invalid_contrast)

  @doc false
  @spec parse_saturation(String.t()) :: {:ok, float()} | {:error, :invalid_saturation}
  def parse_saturation(string), do: parse_factor(string, :invalid_saturation)

  @doc false
  @spec parse_colorize(String.t()) :: {:ok, map()} | {:error, :invalid_colorize}
  def parse_colorize(string) do
    result =
      case String.split(string, ",", trim: false) do
        [opacity, color] ->
          colorize(opacity, color, false)

        [opacity, color, "keep-alpha"] ->
          colorize(opacity, color, true)

        _invalid_arity_or_alpha_policy ->
          :error
      end

    effect_result(result, :invalid_colorize)
  end

  @doc false
  @spec parse_gradient(String.t()) :: {:ok, map()} | {:error, :invalid_gradient}
  def parse_gradient(string) do
    result =
      case String.split(string, ",", trim: false) do
        [opacity, color] ->
          gradient(opacity, color, "down", "0", "1")

        [opacity, color, direction] ->
          gradient(opacity, color, direction, "0", "1")

        [opacity, color, direction, start] ->
          gradient(opacity, color, direction, start, "1")

        [opacity, color, direction, start, stop] ->
          gradient(opacity, color, direction, start, stop)

        _invalid_arity ->
          :error
      end

    effect_result(result, :invalid_gradient)
  end

  defp nonnegative_float(string) do
    with {:ok, value} when value >= 0 <- Value.number(string),
         {:ok, value} <- finite_float(value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp parse_factor(string, reason) do
    with {:ok, value} when value > 0 <- Value.number(string),
         {:ok, value} <- finite_float(value) do
      {:ok, value}
    else
      _invalid -> {:error, reason}
    end
  end

  defp finite_float(value) do
    {:ok, value * 1.0}
  rescue
    ArithmeticError -> :error
  end

  defp effect_result({:ok, effect}, _reason), do: {:ok, effect}
  defp effect_result(_invalid, reason), do: {:error, reason}

  defp colorize(opacity, color, keep_alpha) do
    with {:ok, opacity} <- Value.fraction(opacity),
         {:ok, color} <- Value.color(color) do
      {:ok, %{opacity: opacity, color: color, keep_alpha: keep_alpha}}
    end
  end

  defp gradient(opacity, color, direction, start, stop) do
    with {:ok, opacity} <- Value.fraction(opacity),
         {:ok, color} <- Value.color(color),
         {:ok, angle} <- gradient_direction(direction),
         {:ok, start} <- Value.fraction(start),
         {:ok, stop} <- Value.fraction(stop) do
      {:ok, %{opacity: opacity, color: color, angle: angle, start: start, stop: stop}}
    end
  end

  defp gradient_direction(direction) do
    case Map.fetch(@gradient_directions, direction) do
      {:ok, angle} -> {:ok, angle}
      :error -> numeric_gradient_direction(direction)
    end
  end

  defp numeric_gradient_direction(direction) do
    with {:ok, value} <- Value.number(direction),
         {:ok, value} <- finite_float(value) do
      {:ok, normalize_angle(value)}
    else
      _invalid -> {:error, :invalid_direction}
    end
  end

  defp normalize_angle(angle) do
    normalized = :math.fmod(angle, 360.0)

    cond do
      normalized == 0.0 -> 0.0
      normalized < 0.0 -> normalized + 360.0
      true -> normalized
    end
  end

  @doc false
  @spec parse_trim(String.t()) ::
          {:ok, :auto | {color_value(), number() | nil}} | {:error, atom()}
  def parse_trim("auto"), do: {:ok, :auto}

  def parse_trim(string) do
    case Value.csv(string, 1..2, [&Value.color/1, &parse_tolerance/1]) do
      {:ok, [color]} -> {:ok, {color, nil}}
      {:ok, [color, tolerance]} -> {:ok, {color, tolerance}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_trim_symmetry(String.t()) ::
          {:ok, :horizontal | :vertical | :both} | {:error, :invalid_trim_symmetry}
  def parse_trim_symmetry("h"), do: {:ok, :horizontal}
  def parse_trim_symmetry("v"), do: {:ok, :vertical}
  def parse_trim_symmetry("hv"), do: {:ok, :both}
  def parse_trim_symmetry(_value), do: {:error, :invalid_trim_symmetry}

  defp parse_tolerance(string) do
    case Value.number(string) do
      {:ok, n} when is_number(n) and n >= 0 -> {:ok, n}
      _invalid -> {:error, :invalid_tolerance}
    end
  end

  @doc false
  @spec parse_bg(String.t()) :: {:ok, {color_value(), float() | nil}} | {:error, atom()}
  def parse_bg(string) do
    case Value.csv(string, 1..2, [&Value.color/1, &Value.fraction/1]) do
      {:ok, [color]} -> {:ok, {color, nil}}
      {:ok, [color, alpha]} -> {:ok, {color, alpha}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_orientation(String.t()) :: {:ok, :auto | :none} | {:error, :invalid_orientation}
  def parse_orientation("auto"), do: {:ok, :auto}
  def parse_orientation("none"), do: {:ok, :none}
  def parse_orientation(_value), do: {:error, :invalid_orientation}

  @doc false
  @spec parse_output(String.t()) :: {:ok, :image | :blurhash | :info} | {:error, :invalid_output}
  def parse_output(string) do
    case Map.fetch(@output_map, string) do
      {:ok, output} -> {:ok, output}
      :error -> {:error, :invalid_output}
    end
  end

  @doc false
  @spec parse_filename(String.t()) :: {:ok, String.t()} | {:error, :invalid_filename}
  def parse_filename(string), do: parse_path_token(string, :invalid_filename)

  @doc false
  @spec parse_cachebuster(String.t()) :: {:ok, String.t()} | {:error, :invalid_cachebuster}
  def parse_cachebuster(string), do: parse_path_token(string, :invalid_cachebuster)

  @doc false
  @spec parse_format(String.t()) ::
          {:ok, :avif | :webp | :jpeg | :png | :jpeg_xl} | {:error, :invalid_format}
  def parse_format(string) do
    case Map.fetch(@format_map, string) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, :invalid_format}
    end
  end

  @doc false
  @spec parse_metadata(String.t()) ::
          {:ok, :strip | :copyright | :keep} | {:error, :invalid_metadata}
  def parse_metadata(string), do: parse_enum(string, @metadata_map, :invalid_metadata)

  @doc false
  @spec parse_color_profile(String.t()) ::
          {:ok, :strip | :preserve_source | {:convert, :srgb | :display_p3 | :adobe_rgb}}
          | {:error, :invalid_color_profile}
  def parse_color_profile(string),
    do: parse_enum(string, @color_profile_map, :invalid_color_profile)

  @doc false
  @spec parse_hdr(String.t()) ::
          {:ok, :tone_map | :preserve} | {:error, :invalid_hdr}
  def parse_hdr(string), do: parse_enum(string, @hdr_map, :invalid_hdr)

  @doc false
  @spec parse_quality(String.t()) :: {:ok, 1..100} | {:error, :invalid_quality}
  def parse_quality(string) do
    case Value.number(string) do
      {:ok, n} when is_integer(n) and n >= 1 and n <= 100 -> {:ok, n}
      _invalid -> {:error, :invalid_quality}
    end
  end

  @doc false
  @spec parse_format_qualities(String.t()) ::
          {:ok, %{optional(atom()) => {:quality, 1..100}}}
          | {:error, :invalid_format_qualities}
  def parse_format_qualities(string) do
    case OutputOptions.parse_format_qualities(string) do
      {:ok, qualities} -> {:ok, qualities}
      :error -> {:error, :invalid_format_qualities}
    end
  end

  @doc false
  @spec parse_autoquality(String.t()) :: {:ok, term()} | {:error, :invalid_autoquality}
  def parse_autoquality(string) do
    case OutputOptions.parse_autoquality(string) do
      {:ok, autoquality} -> {:ok, autoquality}
      :error -> {:error, :invalid_autoquality}
    end
  end

  @doc false
  @spec parse_max_bytes(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_max_bytes}
  def parse_max_bytes(string) do
    case OutputOptions.parse_max_bytes(string) do
      {:ok, max_bytes} -> {:ok, max_bytes}
      :error -> {:error, :invalid_max_bytes}
    end
  end

  @doc false
  def parse_jpeg_options(string), do: parse_encoder_options(string, :jpeg)

  @doc false
  def parse_png_options(string), do: parse_encoder_options(string, :png)

  @doc false
  def parse_webp_options(string), do: parse_encoder_options(string, :webp)

  @doc false
  def parse_avif_options(string), do: parse_encoder_options(string, :avif)

  @doc false
  def parse_jxl_options(string), do: parse_encoder_options(string, :jpeg_xl)

  defp parse_path_token(string, error) do
    case Regex.match?(@path_token_pattern, string) do
      true -> {:ok, string}
      false -> {:error, error}
    end
  end

  defp parse_enum(string, values, error) do
    case Map.fetch(values, string) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, error}
    end
  end

  defp parse_encoder_options(string, format) do
    parser =
      case format do
        :jpeg -> &OutputOptions.parse_jpeg_options/1
        :png -> &OutputOptions.parse_png_options/1
        :webp -> &OutputOptions.parse_webp_options/1
        :avif -> &OutputOptions.parse_avif_options/1
        :jpeg_xl -> &OutputOptions.parse_jxl_options/1
      end

    case parser.(string) do
      {:ok, options} -> {:ok, options}
      :error -> {:error, :invalid_encoder_options}
    end
  end

  @doc false
  @spec parse_expires(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_expires}
  def parse_expires(string) do
    case Value.number(string) do
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      _invalid -> {:error, :invalid_expires}
    end
  end

  @doc false
  @spec parse_preset_names(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_preset_name}
  def parse_preset_names(string) do
    names = String.split(string, ",")

    if Enum.all?(names, &Regex.match?(@preset_name_pattern, &1)) do
      {:ok, names}
    else
      {:error, :invalid_preset_name}
    end
  end
end

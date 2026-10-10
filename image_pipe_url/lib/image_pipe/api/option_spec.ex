defmodule ImagePipe.API.OptionSpec do
  import ImagePipe.Plan.ValueBounds
  # Declarative option table for the ImagePipe URL API.
  #
  # Each `%OptionSpec{}` defines an option's URL key, canonical name, scope, and value
  # parser. Semantic constraints are owned by `ImagePipe.Plan.Spec`.
  @moduledoc false

  alias ImagePipe.API.OutputOptions
  alias ImagePipe.API.Value
  alias ImagePipe.Plan.ValueSpellings

  @enforce_keys [
    :key,
    :name,
    :scope,
    :value
  ]
  defstruct @enforce_keys

  @type value_parser :: (String.t() -> {:ok, term()} | {:error, atom()})
  @type length_value :: {:px, number()} | {:pct, number()}
  @type color_value :: {0..255, 0..255, 0..255}

  @type t :: %__MODULE__{
          key: String.t(),
          name: atom(),
          scope: :group | :request,
          value: :flag | {:flag, value_parser()} | value_parser()
        }

  @fit_map ValueSpellings.spellings(:fit)
  @anchor_map ValueSpellings.spellings(:anchor)
  @axis_map ValueSpellings.spellings(:axis)
  @format_map ValueSpellings.spellings(:format)
  @output_map ValueSpellings.spellings(:output)
  @metadata_map ValueSpellings.spellings(:metadata)
  @color_profile_map ValueSpellings.spellings(:color_profile)
  @hdr_map ValueSpellings.spellings(:hdr)

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
        name: :rotate,
        scope: :group,
        value: &__MODULE__.parse_rotate/1
      },
      %__MODULE__{
        key: "flip",
        name: :flip,
        scope: :group,
        value: &__MODULE__.parse_flip/1
      },
      %__MODULE__{
        key: "gray",
        name: :gray,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "bitonal",
        name: :bitonal,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "dpr",
        name: :dpr,
        scope: :group,
        value: &__MODULE__.parse_dpr/1
      },
      %__MODULE__{
        key: "w",
        name: :width,
        scope: :group,
        value: &__MODULE__.parse_dimension/1
      },
      %__MODULE__{
        key: "h",
        name: :height,
        scope: :group,
        value: &__MODULE__.parse_dimension/1
      },
      %__MODULE__{
        key: "min-w",
        name: :min_width,
        scope: :group,
        value: &__MODULE__.parse_min_dimension/1
      },
      %__MODULE__{
        key: "min-h",
        name: :min_height,
        scope: :group,
        value: &__MODULE__.parse_min_dimension/1
      },
      %__MODULE__{
        key: "fit",
        name: :fit,
        scope: :group,
        value: &__MODULE__.parse_fit/1
      },
      %__MODULE__{
        key: "enlarge",
        name: :enlarge,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "zoom",
        name: :zoom,
        scope: :group,
        value: &__MODULE__.parse_zoom/1
      },
      %__MODULE__{
        key: "extend",
        name: :extend,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "extend-ratio",
        name: :extend_ratio,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "extend-at",
        name: :extend_at,
        scope: :group,
        value: &__MODULE__.parse_named_anchor/1
      },
      %__MODULE__{
        key: "extend-offset",
        name: :extend_offset,
        scope: :group,
        value: &__MODULE__.parse_offset/1
      },
      %__MODULE__{
        key: "crop",
        name: :crop,
        scope: :group,
        value: &__MODULE__.parse_crop/1
      },
      %__MODULE__{
        key: "crop-ratio",
        name: :crop_ratio,
        scope: :group,
        value: &__MODULE__.parse_crop_ratio/1
      },
      %__MODULE__{
        key: "crop-ratio-enlarge",
        name: :crop_ratio_enlarge,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "region",
        name: :region,
        scope: :group,
        value: &__MODULE__.parse_region/1
      },
      %__MODULE__{
        key: "anchor",
        name: :anchor,
        scope: :group,
        value: &__MODULE__.parse_anchor/1
      },
      %__MODULE__{
        key: "anchor-offset",
        name: :anchor_offset,
        scope: :group,
        value: &__MODULE__.parse_offset/1
      },
      %__MODULE__{
        key: "focus",
        name: :focus,
        scope: :group,
        value: &__MODULE__.parse_focus/1
      },
      %__MODULE__{
        key: "detect",
        name: :detect,
        scope: :group,
        value: &__MODULE__.parse_detect/1
      },
      %__MODULE__{
        key: "progressive-blur",
        name: :progressive_blur,
        scope: :group,
        value: &__MODULE__.parse_progressive_blur/1
      },
      %__MODULE__{
        key: "blur",
        name: :blur,
        scope: :group,
        value: &__MODULE__.parse_blur/1
      },
      %__MODULE__{
        key: "sharpen",
        name: :sharpen,
        scope: :group,
        value: &__MODULE__.parse_sharpen/1
      },
      %__MODULE__{
        key: "pixelate",
        name: :pixelate,
        scope: :group,
        value: &__MODULE__.parse_pixelate/1
      },
      %__MODULE__{
        key: "monochrome",
        name: :monochrome,
        scope: :group,
        value: &__MODULE__.parse_monochrome/1
      },
      %__MODULE__{
        key: "duotone",
        name: :duotone,
        scope: :group,
        value: &__MODULE__.parse_duotone/1
      },
      %__MODULE__{
        key: "brightness",
        name: :brightness,
        scope: :group,
        value: &__MODULE__.parse_brightness/1
      },
      %__MODULE__{
        key: "contrast",
        name: :contrast,
        scope: :group,
        value: &__MODULE__.parse_contrast/1
      },
      %__MODULE__{
        key: "saturation",
        name: :saturation,
        scope: :group,
        value: &__MODULE__.parse_saturation/1
      },
      %__MODULE__{
        key: "colorize",
        name: :colorize,
        scope: :group,
        value: &__MODULE__.parse_colorize/1
      },
      %__MODULE__{
        key: "gradient",
        name: :gradient,
        scope: :group,
        value: &__MODULE__.parse_gradient/1
      },
      %__MODULE__{
        key: "trim",
        name: :trim,
        scope: :group,
        value: &__MODULE__.parse_trim/1
      },
      %__MODULE__{
        key: "trim-symmetry",
        name: :trim_symmetry,
        scope: :group,
        value: &__MODULE__.parse_trim_symmetry/1
      },
      %__MODULE__{
        key: "pad",
        name: :padding,
        scope: :group,
        value: &Value.pad_shorthand/1
      },
      %__MODULE__{
        key: "bg",
        name: :background,
        scope: :group,
        value: &__MODULE__.parse_bg/1
      },
      %__MODULE__{
        key: "wm",
        name: :watermark,
        scope: :group,
        value: &__MODULE__.parse_watermark/1
      },
      %__MODULE__{
        key: "wm-src64",
        name: :watermark_source,
        scope: :group,
        value: &__MODULE__.parse_watermark_source/1
      },
      %__MODULE__{
        key: "wm-enc",
        name: :watermark_token,
        scope: :group,
        value: &__MODULE__.parse_watermark_token/1
      },
      %__MODULE__{
        key: "wm-opacity",
        name: :watermark_opacity,
        scope: :group,
        value: &__MODULE__.parse_watermark_opacity/1
      },
      %__MODULE__{
        key: "wm-scale",
        name: :watermark_scale,
        scope: :group,
        value: &__MODULE__.parse_watermark_scale/1
      },
      %__MODULE__{
        key: "wm-at",
        name: :watermark_at,
        scope: :group,
        value: &__MODULE__.parse_named_anchor/1
      },
      %__MODULE__{
        key: "wm-offset",
        name: :watermark_offset,
        scope: :group,
        value: &__MODULE__.parse_offset/1
      },
      %__MODULE__{
        key: "wm-tile",
        name: :watermark_tile,
        scope: :group,
        value: :flag
      },
      %__MODULE__{
        key: "wm-gap",
        name: :watermark_gap,
        scope: :group,
        value: &__MODULE__.parse_watermark_gap/1
      },
      %__MODULE__{
        key: "orient",
        name: :orient,
        scope: :request,
        value: &__MODULE__.parse_orientation/1
      },
      %__MODULE__{
        key: "page",
        name: :page,
        scope: :request,
        value: &__MODULE__.parse_page/1
      },
      %__MODULE__{
        key: "output",
        name: :terminal,
        scope: :request,
        value: &__MODULE__.parse_output/1
      },
      %__MODULE__{
        key: "format",
        name: :format,
        scope: :request,
        value: &__MODULE__.parse_format/1
      },
      %__MODULE__{
        key: "q",
        name: :quality,
        scope: :request,
        value: &__MODULE__.parse_quality/1
      },
      %__MODULE__{
        key: "format-q",
        name: :format_qualities,
        scope: :request,
        value: &__MODULE__.parse_format_qualities/1
      },
      %__MODULE__{
        key: "meta",
        name: :metadata,
        scope: :request,
        value: &__MODULE__.parse_metadata/1
      },
      %__MODULE__{
        key: "dpi",
        name: :dpi,
        scope: :request,
        value: &__MODULE__.parse_dpi/1
      },
      %__MODULE__{
        key: "profile",
        name: :color_profile,
        scope: :request,
        value: &__MODULE__.parse_color_profile/1
      },
      %__MODULE__{
        key: "hdr",
        name: :hdr,
        scope: :request,
        value: &__MODULE__.parse_hdr/1
      },
      %__MODULE__{
        key: "autoquality",
        name: :autoquality,
        scope: :request,
        value: {:flag, &__MODULE__.parse_autoquality/1}
      },
      %__MODULE__{
        key: "max-bytes",
        name: :max_bytes,
        scope: :request,
        value: &__MODULE__.parse_max_bytes/1
      },
      %__MODULE__{
        key: "jpeg-options",
        name: :jpeg_options,
        scope: :request,
        value: &__MODULE__.parse_jpeg_options/1
      },
      %__MODULE__{
        key: "png-options",
        name: :png_options,
        scope: :request,
        value: &__MODULE__.parse_png_options/1
      },
      %__MODULE__{
        key: "webp-options",
        name: :webp_options,
        scope: :request,
        value: &__MODULE__.parse_webp_options/1
      },
      %__MODULE__{
        key: "avif-options",
        name: :avif_options,
        scope: :request,
        value: &__MODULE__.parse_avif_options/1
      },
      %__MODULE__{
        key: "filename",
        name: :filename,
        scope: :request,
        value: &__MODULE__.parse_filename/1
      },
      %__MODULE__{
        key: "attachment",
        name: :attachment,
        scope: :request,
        value: :flag
      },
      %__MODULE__{
        key: "cb",
        name: :cachebuster,
        scope: :request,
        value: &__MODULE__.parse_cachebuster/1
      },
      %__MODULE__{
        key: "debug",
        name: :debug,
        scope: :request,
        value: :flag
      },
      %__MODULE__{
        key: "expires",
        name: :expires,
        scope: :request,
        value: &__MODULE__.parse_expires/1
      },
      %__MODULE__{
        key: "preset",
        name: :presets,
        scope: :group,
        value: &__MODULE__.parse_preset_names/1
      }
    ]
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
    if positive_decimal?(string) do
      case Float.parse(string) do
        {value, ""} when scale?(value) -> {:ok, value}
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
          {:ok, :contain | :cover | :stretch | :auto} | {:error, :invalid_fit}
  def parse_fit(string), do: parse_enum(string, @fit_map, :invalid_fit)

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
    if positive_decimal?(string) do
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
    with true <- chars?(numerator, :digit),
         true <- chars?(denominator, :digit),
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

  # Reduced ratio components fit the native axis range.
  defp pixel_geometry_ratio?({:ratio, numerator, denominator}) do
    axis?(numerator) and axis?(denominator)
  end

  @doc false
  @spec parse_region(String.t()) ::
          {:ok, {length_value(), length_value(), length_value(), length_value()}}
          | {:error, atom()}
  def parse_region(string) do
    case Value.csv(string, 4..4, [
           &non_negative_length/1,
           &non_negative_length/1,
           &positive_length/1,
           &positive_length/1
         ]) do
      {:ok, [x, y, w, h]} -> {:ok, {x, y, w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp non_negative_length(string) do
    case Value.length(string) do
      {:ok, {_unit, value} = length} when value >= 0 -> {:ok, length}
      _invalid -> {:error, :invalid_length}
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
  def parse_anchor(string), do: parse_enum(string, @anchor_map, :invalid_anchor)

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
          {:ok, [{:all | String.t(), float()}]}
          | {:error, :invalid_detect}
  def parse_detect(string) do
    with {:ok, pairs} <- parse_detect_items(String.split(string, ",")),
         true <- unique_detect_classes?(pairs) do
      {:ok, pairs}
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
    if valid_detect_class?(class), do: {:ok, {detect_class(class), 1.0}}, else: :error
  end

  defp parse_detect_item([class, weight]) do
    with true <- valid_detect_class?(class),
         {:ok, weight} <- positive_decimal(weight),
         true <- weight <= @max_detect_weight do
      {:ok, {detect_class(class), weight}}
    else
      _invalid -> :error
    end
  end

  defp parse_detect_item(_invalid), do: :error

  defp valid_detect_class?(class),
    do: class != "unset" and detect_class?(class)

  defp unique_detect_classes?(pairs) do
    classes = Enum.map(pairs, &elem(&1, 0))
    Enum.uniq(classes) == classes
  end

  defp detect_class("all"), do: :all
  defp detect_class(class), do: class

  @doc false
  @spec parse_offset(String.t()) ::
          {:ok, {length_value(), length_value()}} | {:error, :invalid_offset}
  def parse_offset(string) do
    case Value.csv(string, 2..2, [&Value.length/1, &Value.length/1]) do
      {:ok, [x, y]} -> {:ok, {x, y}}
      {:error, _reason} -> {:error, :invalid_offset}
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
      {:ok, angle} -> {:ok, angle}
      {:error, _reason} -> {:error, :invalid_rotation}
    end
  end

  @spec parse_flip(String.t()) ::
          {:ok, :horizontal | :vertical | :both} | {:error, :invalid_flip}
  def parse_flip(string), do: parse_enum(string, @axis_map, :invalid_flip)

  @doc false
  @spec parse_blur(String.t()) :: {:ok, float()} | {:error, :invalid_blur}
  def parse_blur(string) do
    case nonnegative_float(string) do
      {:ok, value} when blur?(value) -> {:ok, value}
      _invalid -> {:error, :invalid_blur}
    end
  end

  @doc false
  @spec parse_sharpen(String.t()) :: {:ok, float()} | {:error, :invalid_sharpen}
  def parse_sharpen(string) do
    case nonnegative_float(string) do
      {:ok, value} when sharpen?(value) -> {:ok, value}
      _invalid -> {:error, :invalid_sharpen}
    end
  end

  @doc false
  @spec parse_pixelate(String.t()) :: {:ok, pos_integer()} | {:error, :invalid_pixelate}
  def parse_pixelate(string) do
    if chars?(string, :digit) do
      case String.to_integer(string) do
        value when axis?(value) -> {:ok, value}
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

        [intensity, shadow] ->
          with {:ok, intensity} <- Value.fraction(intensity),
               {:ok, shadow} <- Value.color(shadow) do
            {:ok, %{intensity: intensity, shadow: shadow, highlight: {255, 255, 255}}}
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
    if signed_integer?(string) do
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

  @doc false
  def parse_progressive_blur(string) do
    result =
      case String.split(string, ",", trim: false) do
        [sigma] -> progressive_blur(sigma, "down", "0", "1")
        [sigma, direction] -> progressive_blur(sigma, direction, "0", "1")
        [sigma, direction, start] -> progressive_blur(sigma, direction, start, "1")
        [sigma, direction, start, stop] -> progressive_blur(sigma, direction, start, stop)
        _invalid -> :error
      end

    effect_result(result, :invalid_progressive_blur)
  end

  defp progressive_blur(sigma, direction, start, stop) do
    with {:ok, sigma} when blur?(sigma) <- nonnegative_float(sigma),
         {:ok, angle} <- gradient_direction(direction),
         {:ok, start} <- Value.fraction(start),
         {:ok, stop} <- Value.fraction(stop) do
      {:ok, %{sigma: sigma, angle: angle, start: start, stop: stop}}
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
      {:ok, value}
    else
      _invalid -> {:error, :invalid_direction}
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
  def parse_trim_symmetry(string),
    do: parse_enum(string, @axis_map, :invalid_trim_symmetry)

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
  @spec parse_watermark(String.t()) :: {:ok, String.t()} | {:error, :invalid_watermark}
  def parse_watermark(string) do
    case chars?(string, :name) do
      true -> {:ok, string}
      false -> {:error, :invalid_watermark}
    end
  end

  @doc false
  @spec parse_watermark_source(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_watermark_source}
  def parse_watermark_source(string) do
    case not String.contains?(string, "=") and Base.url_decode64(string, padding: false) do
      {:ok, source} when source != "" ->
        if String.valid?(source), do: {:ok, source}, else: {:error, :invalid_watermark_source}

      _invalid ->
        {:error, :invalid_watermark_source}
    end
  end

  @doc false
  @spec parse_watermark_token(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_watermark_token}
  def parse_watermark_token(string) do
    case chars?(string, :base64url) do
      true -> {:ok, string}
      false -> {:error, :invalid_watermark_token}
    end
  end

  @doc false
  @spec parse_watermark_opacity(String.t()) ::
          {:ok, float()} | {:error, :invalid_watermark_opacity}
  def parse_watermark_opacity(string) do
    case Value.fraction(string) do
      {:ok, opacity} -> {:ok, opacity}
      {:error, _reason} -> {:error, :invalid_watermark_opacity}
    end
  end

  @doc false
  @spec parse_watermark_scale(String.t()) ::
          {:ok, float()} | {:error, :invalid_watermark_scale}
  def parse_watermark_scale(string) do
    case Value.fraction(string) do
      {:ok, scale} when scale > 0 -> {:ok, scale}
      _invalid -> {:error, :invalid_watermark_scale}
    end
  end

  @doc false
  @spec parse_watermark_gap(String.t()) ::
          {:ok, {length_value(), length_value()}} | {:error, :invalid_watermark_gap}
  def parse_watermark_gap(string) do
    case parse_offset(string) do
      {:ok, {{_x_unit, x}, {_y_unit, y}} = gap} when x >= 0 and y >= 0 -> {:ok, gap}
      _invalid -> {:error, :invalid_watermark_gap}
    end
  end

  @doc false
  @spec parse_page(String.t()) :: {:ok, non_neg_integer()} | {:error, :invalid_page}
  def parse_page(string) do
    if chars?(string, :digit),
      do: {:ok, String.to_integer(string)},
      else: {:error, :invalid_page}
  end

  @doc false
  @spec parse_orientation(String.t()) :: {:ok, :auto | :none} | {:error, :invalid_orientation}
  def parse_orientation("auto"), do: {:ok, :auto}
  def parse_orientation("none"), do: {:ok, :none}
  def parse_orientation(_value), do: {:error, :invalid_orientation}

  @doc false
  @spec parse_output(String.t()) ::
          {:ok, :image | :blurhash | :lqip_css | :info | {:info, [:blurhash | :lqip_css, ...]}}
          | {:error, :invalid_output}
  def parse_output(string), do: output_value(String.split(string, ","))

  defp output_value([output]) do
    case Map.fetch(@output_map, output) do
      {:ok, output} -> {:ok, output}
      :error -> {:error, :invalid_output}
    end
  end

  defp output_value(["info" | flags]) do
    placeholders = Enum.map(flags, &Map.get(@output_map, &1))

    if Enum.all?(placeholders, &(&1 in [:blurhash, :lqip_css])) and
         placeholders == Enum.uniq(placeholders),
       do: {:ok, {:info, Enum.sort(placeholders)}},
       else: {:error, :invalid_output}
  end

  defp output_value(_values), do: {:error, :invalid_output}

  @doc false
  @spec parse_filename(String.t()) :: {:ok, String.t()} | {:error, :invalid_filename}
  def parse_filename(string), do: parse_path_token(string, :invalid_filename)

  @doc false
  @spec parse_cachebuster(String.t()) :: {:ok, String.t()} | {:error, :invalid_cachebuster}
  def parse_cachebuster(string), do: parse_path_token(string, :invalid_cachebuster)

  @doc false
  @spec parse_format(String.t()) ::
          {:ok, :avif | :webp | :jpeg | :png} | {:error, :invalid_format}
  def parse_format(string), do: parse_enum(string, @format_map, :invalid_format)

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
          {:ok, qualities | {:unset, qualities}} | {:error, :invalid_format_qualities}
        when qualities: %{optional(atom()) => {:quality, 1..100}}
  def parse_format_qualities("unset," <> string) do
    with {:ok, qualities} <- format_qualities(string), do: {:ok, {:unset, qualities}}
  end

  def parse_format_qualities(string), do: format_qualities(string)

  defp format_qualities(string) do
    case OutputOptions.parse_format_qualities(string) do
      {:ok, qualities} -> {:ok, qualities}
      :error -> {:error, :invalid_format_qualities}
    end
  end

  @doc false
  @spec parse_autoquality(String.t()) :: {:ok, float()} | {:error, :invalid_autoquality}
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
  @spec parse_dpi(String.t()) :: {:ok, 1..65_535} | {:error, :invalid_dpi}
  def parse_dpi(string) do
    case OutputOptions.parse_dpi(string) do
      {:ok, dpi} -> {:ok, dpi}
      :error -> {:error, :invalid_dpi}
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

  defp parse_path_token(string, error) do
    case chars?(string, :token) do
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

  defp parse_encoder_options("unset," <> string, format) do
    with {:ok, options} <- encoder_options(string, format), do: {:ok, {:unset, options}}
  end

  defp parse_encoder_options(string, format), do: encoder_options(string, format)

  defp encoder_options(string, format) do
    parser =
      case format do
        :jpeg -> &OutputOptions.parse_jpeg_options/1
        :png -> &OutputOptions.parse_png_options/1
        :webp -> &OutputOptions.parse_webp_options/1
        :avif -> &OutputOptions.parse_avif_options/1
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

    if Enum.all?(names, &chars?(&1, :token)) do
      {:ok, names}
    else
      {:error, :invalid_preset_name}
    end
  end

  # Grammar checks scan bytes: OTP 28 and later rebuild a regex attribute at
  # every use.

  # `[0-9]+(\.[0-9]+)?`
  defp positive_decimal?(string) do
    case :binary.split(string, ".") do
      [whole] -> chars?(whole, :digit)
      [whole, fraction] -> chars?(whole, :digit) and chars?(fraction, :digit)
    end
  end

  defp signed_integer?("-" <> digits), do: chars?(digits, :digit)
  defp signed_integer?(digits), do: chars?(digits, :digit)

  # `[a-z0-9][a-z0-9_-]*`
  defp detect_class?(<<first, rest::binary>>),
    do: (first in ?a..?z or first in ?0..?9) and (rest == "" or chars?(rest, :name))

  defp detect_class?(_empty), do: false

  # One or more bytes of `class`.
  defp chars?(<<char, rest::binary>>, class),
    do: char?(char, class) and (rest == "" or chars?(rest, class))

  defp chars?(_empty, _class), do: false

  defp char?(char, :digit), do: char in ?0..?9
  defp char?(char, :name), do: char in ?a..?z or char in ?0..?9 or char in [?_, ?-]

  defp char?(char, :base64url),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-]

  defp char?(char, :token),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?., ?_, ?-]
end

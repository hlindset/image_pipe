defmodule ImagePipe.Native.OptionSpec do
  @moduledoc """
  Declarative option table for the native URL API
  [native §Architecture, option schema].

  One `%OptionSpec{}` per native option. The table
  drives *mechanical* concerns only — key lookup, scope/duplicate
  validation, per-segment value dispatch, and terminal-applicability
  rejection; complex cross-option semantics (resize intent, guide
  consumers, group assembly) stay ordinary code in
  `ImagePipe.Native.Parser`.

  A completeness test (`option_spec_test.exs`) requires every entry to
  populate all fields and carry at least one example — "easy to document"
  as a maintained invariant.
  """

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
          # Documentation-only in this probe: nothing reads this field to
          # drive validation. The resize-intent/guide-consumer inertness
          # logic it names is hand-written in `Parser`'s
          # `tier2_group_errors/3` (and helpers), not table-driven from
          # here.
          prerequisites: [atom()],
          conflicts: [String.t()],
          identity: :representation | :gate | :presentation,
          terminal_applicability: :both | :image,
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
    "blurhash" => :blurhash
  }

  @preset_name_pattern ~r/\A[A-Za-z0-9._-]+\z/
  @positive_decimal_pattern ~r/\A[0-9]+(?:\.[0-9]+)?\z/
  @unsigned_integer_pattern ~r/\A[0-9]+\z/
  @detect_class_pattern ~r/\A[a-z0-9][a-z0-9_-]*\z/
  @max_vips_axis 2_147_483_647
  @max_detect_weight 1_000_000.0

  @doc """
  Every declared probe-subset option, in a stable order matching the
  vocabulary tables in [native §Option vocabulary].
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
        summary: "Gaussian blur sigma; 0 is the Tier-1 identity point",
        examples: ["blur=2.5"]
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
        summary: "Terminal selection: image (default) or blurhash",
        examples: ["output=blurhash"]
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
        key: "debug",
        scope: :request,
        value: :flag,
        stage: nil,
        default: false,
        prerequisites: [],
        conflicts: [],
        identity: :presentation,
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
        terminal_applicability: :both,
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
  # Each parses only its own segment's value shape [native §Value
  # micro-syntax]; cross-option assembly (combining w/h/fit/enlarge into a
  # resize map, defaulting an omitted trim tolerance, etc.) is the parser
  # module's job, not this table's.

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
    case Value.number(string) do
      {:ok, n} when is_number(n) and n >= 0 -> {:ok, n * 1.0}
      _invalid -> {:error, :invalid_blur}
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
  @spec parse_output(String.t()) :: {:ok, :image | :blurhash} | {:error, :invalid_output}
  def parse_output(string) do
    case Map.fetch(@output_map, string) do
      {:ok, output} -> {:ok, output}
      :error -> {:error, :invalid_output}
    end
  end

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
  @spec parse_quality(String.t()) :: {:ok, 1..100} | {:error, :invalid_quality}
  def parse_quality(string) do
    case Value.number(string) do
      {:ok, n} when is_integer(n) and n >= 1 and n <= 100 -> {:ok, n}
      _invalid -> {:error, :invalid_quality}
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

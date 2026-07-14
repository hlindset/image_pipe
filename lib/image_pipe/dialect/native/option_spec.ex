defmodule ImagePipe.Dialect.Native.OptionSpec do
  @moduledoc """
  Declarative option table for the native URL dialect's probe subset
  [native §Architecture, option schema].

  One `%OptionSpec{}` per probe-subset key (`w h fit enlarge crop region
  anchor focus blur trim pad bg output format q expires preset`). The table
  drives *mechanical* concerns only — key lookup, scope/duplicate
  validation, per-segment value dispatch, and terminal-applicability
  rejection; complex cross-option semantics (resize intent, guide
  consumers, group assembly) stay ordinary code in
  `ImagePipe.Dialect.Native.Parser`.

  A completeness test (`option_spec_test.exs`) requires every entry to
  populate all fields and carry at least one example — "easy to document"
  as a maintained invariant.
  """

  alias ImagePipe.Dialect.Native.Value

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
          identity: :representation | :gate,
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
    "smart" => :smart
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

  @preset_name_pattern ~r/^[A-Za-z0-9._-]+$/

  @doc """
  Every declared probe-subset option, in a stable order matching the
  vocabulary tables in [native §Option vocabulary].
  """
  @spec all() :: [t()]
  def all do
    [
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
        conflicts: ["focus"],
        identity: :representation,
        terminal_applicability: :both,
        summary: "Crop guide / gravity for a guided crop or cover-family resize",
        examples: ["anchor=smart"]
      },
      %__MODULE__{
        key: "focus",
        scope: :group,
        value: &__MODULE__.parse_focus/1,
        stage: 6,
        default: nil,
        prerequisites: [:guide_consumer],
        conflicts: ["anchor"],
        identity: :representation,
        terminal_applicability: :both,
        summary: "Focal point as x,y unit-space fractions (0.0-1.0)",
        examples: ["focus=0.25,0.75"]
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
    case Value.csv(string, 2..2, [&Value.length/1, &Value.length/1]) do
      {:ok, [w, h]} -> {:ok, {w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec parse_region(String.t()) ::
          {:ok, {length_value(), length_value(), length_value(), length_value()}}
          | {:error, atom()}
  def parse_region(string) do
    case Value.csv(string, 4..4, [
           &Value.length/1,
           &Value.length/1,
           &Value.length/1,
           &Value.length/1
         ]) do
      {:ok, [x, y, w, h]} -> {:ok, {x, y, w, h}}
      {:error, reason} -> {:error, reason}
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
           | :smart}
          | {:error, :invalid_anchor}
  def parse_anchor(string) do
    case Map.fetch(@anchor_map, string) do
      {:ok, anchor} -> {:ok, anchor}
      :error -> {:error, :invalid_anchor}
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

defmodule ImagePipe.Plan.Color do
  @moduledoc """
  Canonical product-neutral color model for Plan operations.

  Colors are represented as sRGB channels with a canonical alpha ratio. The
  `:color` dependency stays behind this module so parser, runtime, and cache
  data do not depend on third-party structs.
  """

  alias Elixir.Color.CSS.Names, as: CssNames
  alias Elixir.Color.SRGB

  @enforce_keys [:space, :channels, :alpha]
  defstruct @enforce_keys

  @type channel :: 0..255
  @type alpha :: {:ratio, non_neg_integer(), pos_integer()}
  @type t :: %__MODULE__{
          space: :srgb,
          channels: {channel(), channel(), channel()},
          alpha: alpha()
        }

  @doc "Opaque sRGB white — the product-neutral flatten/background default (imgproxy's `color.White`)."
  @spec white() :: t()
  def white, do: %__MODULE__{space: :srgb, channels: {255, 255, 255}, alpha: {:ratio, 1, 1}}

  @spec rgb(term(), term(), term()) :: {:ok, t()} | {:error, term()}
  def rgb(red, green, blue)
      when is_integer(red) and red in 0..255 and is_integer(green) and green in 0..255 and
             is_integer(blue) and blue in 0..255 do
    rgba(red, green, blue, {:ratio, 1, 1})
  end

  def rgb(red, green, blue), do: {:error, {:invalid_color, [red, green, blue]}}

  @spec rgb_hex(term()) :: {:ok, t()} | {:error, term()}
  def rgb_hex(hex) when is_binary(hex) and byte_size(hex) in [3, 6] do
    with {:ok, %SRGB{} = external} <- SRGB.parse("#" <> hex),
         {red, green, blue} <- SRGB.scale255(external) do
      rgb(round(red), round(green), round(blue))
    else
      {:error, _reason} -> {:error, {:invalid_color, [hex]}}
    end
  end

  def rgb_hex(hex), do: {:error, {:invalid_color, [hex]}}

  @doc """
  Looks up a CSS named color (the full CSS Color Module Level 4 list,
  including its aliases such as `cyan`/`aqua`, `magenta`/`fuchsia`,
  `grey`/`gray`) and returns its 8-bit sRGB channel tuple. Returns a bare
  tuple rather than `t()`, mirroring how callers such as the native
  dialect's `Value.color/1` combine a color's channels with a
  separately-parsed alpha before building a `t()`.
  """
  @spec rgb_name(term()) :: {:ok, {channel(), channel(), channel()}} | {:error, term()}
  def rgb_name(name) when is_binary(name) do
    case CssNames.lookup(name) do
      {:ok, {red, green, blue}} -> {:ok, {red, green, blue}}
      {:error, _reason} -> {:error, {:invalid_color, [name]}}
    end
  end

  def rgb_name(name), do: {:error, {:invalid_color, [name]}}

  @spec rgba(term(), term(), term(), term()) :: {:ok, t()} | {:error, term()}
  def rgba(red, green, blue, alpha)
      when is_integer(red) and red in 0..255 and is_integer(green) and green in 0..255 and
             is_integer(blue) and blue in 0..255 do
    with {:ok, alpha} <- alpha_ratio(alpha),
         {:ok, _external} <- Color.new([red, green, blue]) do
      {:ok,
       %__MODULE__{
         space: :srgb,
         channels: {red, green, blue},
         alpha: alpha
       }}
    else
      {:error, _reason} -> {:error, {:invalid_color, [red, green, blue, alpha]}}
    end
  end

  def rgba(red, green, blue, alpha), do: {:error, {:invalid_color, [red, green, blue, alpha]}}

  @spec with_alpha(t(), alpha()) :: {:ok, t()} | {:error, term()}
  def with_alpha(%__MODULE__{} = color, alpha) do
    with true <- valid?(color),
         {:ok, alpha} <- alpha_ratio(alpha) do
      {:ok, %{color | alpha: alpha}}
    else
      _reason -> {:error, {:invalid_color, [color, alpha]}}
    end
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{space: :srgb, channels: {red, green, blue}, alpha: alpha}) do
    is_integer(red) and red in 0..255 and
      is_integer(green) and green in 0..255 and
      is_integer(blue) and blue in 0..255 and
      match?({:ok, _alpha}, alpha_ratio(alpha))
  end

  def valid?(_color), do: false

  @spec key_data(t()) :: keyword()
  def key_data(%__MODULE__{
        space: :srgb,
        channels: {red, green, blue},
        alpha: {:ratio, numerator, denominator}
      }) do
    [
      space: :srgb,
      red: red,
      green: green,
      blue: blue,
      alpha: [unit: :ratio, numerator: numerator, denominator: denominator]
    ]
  end

  @spec to_rgb_list(t()) :: [channel()]
  def to_rgb_list(%__MODULE__{channels: {red, green, blue}}), do: [red, green, blue]

  @spec to_rgba_list(t()) :: [channel()]
  def to_rgba_list(%__MODULE__{channels: {red, green, blue}, alpha: alpha}) do
    [red, green, blue, alpha_byte(alpha)]
  end

  defp alpha_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0 and numerator <= denominator do
    divisor = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, divisor), div(denominator, divisor)}}
  end

  defp alpha_ratio(_alpha), do: {:error, :alpha}

  defp alpha_byte({:ratio, numerator, denominator}), do: round(255 * numerator / denominator)
end

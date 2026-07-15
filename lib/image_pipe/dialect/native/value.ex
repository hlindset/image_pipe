defmodule ImagePipe.Dialect.Native.Value do
  @moduledoc """
  Pure parsers for the native URL dialect's value micro-syntax [native
  §Value micro-syntax].

  Each function parses exactly one value shape from a raw segment-value
  string and returns `{:ok, value} | {:error, reason_atom}`. These are pure
  functions: no conn, no config, no span attachment — span attachment is
  the caller's job.

  Range/consumer validation beyond the shape itself (e.g. that a `brightness`
  number falls within -100..100, or that a `dimension` result is combined
  with a resize consumer) is also the caller's job; this module only knows
  the grammar.
  """

  alias ImagePipe.Plan.Color, as: PlanColor

  @css_name_pattern ~r/^[a-z]+$/
  @number_pattern ~r/^-?[0-9]+(\.[0-9]+)?$/
  @nonneg_integer_pattern ~r/^[0-9]+$/

  @doc """
  Parses a plain decimal: an optional leading `-`, digits, and an optional
  `.digits` fraction. No exponent notation, no leading `+`, no whitespace.

  Returns an integer when the input has no decimal point, a float
  otherwise — mirroring the literal form of the input. Range checking
  (e.g. that the option's allowed values are non-negative, or bounded to
  -100..100) is the caller's job: `number/1` does not know which option is
  calling it.
  """
  @spec number(String.t()) :: {:ok, number()} | {:error, :invalid_number}
  def number(string) when is_binary(string) do
    if Regex.match?(@number_pattern, string) do
      {:ok, decimal_to_number(string)}
    else
      {:error, :invalid_number}
    end
  end

  defp decimal_to_number(string) do
    if String.contains?(string, ".") do
      String.to_float(string)
    else
      String.to_integer(string)
    end
  end

  @doc """
  Parses a length: a bare number means pixels, a `pct` suffix means
  percentage of the relevant dimension. No other unit is recognized —
  `80p` is an error, not a pixel value [native §Value micro-syntax].
  """
  @spec length(String.t()) ::
          {:ok, {:px, number()} | {:pct, number()}} | {:error, :invalid_length}
  def length(string) when is_binary(string) do
    case String.split_at(string, byte_size(string) - 3) do
      {numeric_part, "pct"} when numeric_part != "" ->
        with {:ok, n} <- number(numeric_part), do: {:ok, {:pct, n}}

      _no_pct_suffix ->
        with {:ok, n} <- number(string), do: {:ok, {:px, n}}
    end
    |> case do
      {:ok, _value} = ok -> ok
      {:error, :invalid_number} -> {:error, :invalid_length}
    end
  end

  @doc """
  Parses a dimension: a positive integer number of pixels, or the keyword
  `auto`. No sign, no fraction, no `pct` — dimensions are the target-box
  shape (`w`/`h`), not the general length shape [native §Value
  micro-syntax].
  """
  @spec dimension(String.t()) ::
          {:ok, {:px, pos_integer()} | :auto} | {:error, :invalid_dimension}
  def dimension("auto"), do: {:ok, :auto}

  def dimension(string) when is_binary(string) do
    if Regex.match?(@nonneg_integer_pattern, string) do
      case String.to_integer(string) do
        n when n > 0 -> {:ok, {:px, n}}
        _zero_or_less -> {:error, :invalid_dimension}
      end
    else
      {:error, :invalid_dimension}
    end
  end

  @doc """
  Parses a fraction: a decimal in the inclusive 0.0–1.0 range. Used for
  unitless unit-space values such as `focus`, opacity, intensity, alpha,
  and gradient `start`/`stop` [native §Value micro-syntax, §Coordinates].
  """
  @spec fraction(String.t()) :: {:ok, float()} | {:error, :invalid_fraction}
  def fraction(string) when is_binary(string) do
    with {:ok, n} <- number(string),
         true <- n >= 0 and n <= 1 do
      {:ok, n * 1.0}
    else
      _invalid_or_out_of_range -> {:error, :invalid_fraction}
    end
  end

  @doc """
  Parses a color: a bare 3- or 6-digit hex triple (no `#`), or a CSS
  named color from the full CSS Color Module Level 4 named-color list,
  including its aliases (`cyan`/`aqua`, `magenta`/`fuchsia`,
  `grey`/`gray`, and the rest of the 148-name list) [native §Value
  micro-syntax, §Colors]. A 3-digit hex is normalized to its 6-digit
  expansion before decoding, so `fff` and `ffffff` produce the same
  tuple.
  """
  @spec color(String.t()) :: {:ok, {0..255, 0..255, 0..255}} | {:error, :invalid_color}
  def color(string) when is_binary(string) do
    case css_named_color(string) do
      {:ok, rgb} -> {:ok, rgb}
      :error -> parse_hex_color(string)
    end
  end

  # Only attempt named-color resolution for pure lowercase-alpha strings:
  # every CSS named color is a single lowercase word, so this both matches
  # the dialect's lowercase-only grammar and avoids the underlying
  # lookup's underscore/hyphen/case normalization loosening the bare-name
  # match (e.g. treating a hyphenated segment value as an alias for a
  # known name).
  defp css_named_color(string) do
    if Regex.match?(@css_name_pattern, string) do
      case PlanColor.rgb_name(string) do
        {:ok, rgb} -> {:ok, rgb}
        {:error, _reason} -> :error
      end
    else
      :error
    end
  end

  defp parse_hex_color(<<r, g, b>>) do
    if hex_digit?(r) and hex_digit?(g) and hex_digit?(b) do
      decode_hex(<<r, r, g, g, b, b>>)
    else
      {:error, :invalid_color}
    end
  end

  defp parse_hex_color(<<_::binary-size(6)>> = hex6), do: decode_hex(hex6)
  defp parse_hex_color(_other), do: {:error, :invalid_color}

  defp hex_digit?(byte), do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp decode_hex(hex6) do
    case Base.decode16(hex6, case: :mixed) do
      {:ok, <<r, g, b>>} -> {:ok, {r, g, b}}
      _invalid -> {:error, :invalid_color}
    end
  end

  @doc """
  Parses the CSS 1–4 value px shorthand into `{top, right, bottom, left}`,
  following the standard CSS shorthand expansion rules [native §Value
  micro-syntax]. Each value is a non-negative integer number of pixels.
  """
  @spec pad_shorthand(String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}}
          | {:error, :invalid_pad_shorthand}
  def pad_shorthand(string) when is_binary(string) do
    string
    |> String.split(",")
    |> expand_pad_shorthand()
  end

  defp expand_pad_shorthand([a]), do: with_nonneg_pixels([a], fn [v] -> {v, v, v, v} end)

  defp expand_pad_shorthand([a, b]),
    do: with_nonneg_pixels([a, b], fn [t, r] -> {t, r, t, r} end)

  defp expand_pad_shorthand([a, b, c]),
    do: with_nonneg_pixels([a, b, c], fn [t, r, bo] -> {t, r, bo, r} end)

  defp expand_pad_shorthand([a, b, c, d]),
    do: with_nonneg_pixels([a, b, c, d], fn [t, r, bo, l] -> {t, r, bo, l} end)

  defp expand_pad_shorthand(_other_arity), do: {:error, :invalid_pad_shorthand}

  defp with_nonneg_pixels(values, expand) do
    case parse_all_nonneg_pixels(values) do
      {:ok, ints} -> {:ok, expand.(ints)}
      :error -> {:error, :invalid_pad_shorthand}
    end
  end

  defp parse_all_nonneg_pixels(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      if Regex.match?(@nonneg_integer_pattern, value) do
        {:cont, {:ok, [String.to_integer(value) | acc]}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, ints} -> {:ok, Enum.reverse(ints)}
      :error -> :error
    end
  end

  @doc """
  Parses a comma-separated list of fixed-arity-range positional values,
  applying one parser per position [native §Value micro-syntax,
  §Pairs/lists]. `arity` is the inclusive range of accepted element
  counts; `parsers` supplies one parser per position, up to the maximum
  arity — positions beyond the actual element count are simply not
  invoked.
  """
  @spec csv(String.t(), Range.t(), [(String.t() -> {:ok, term()} | {:error, term()})]) ::
          {:ok, [term()]} | {:error, :invalid_arity | :invalid_element}
  def csv(string, %Range{} = arity, parsers) when is_binary(string) and is_list(parsers) do
    parts = String.split(string, ",")

    if Enum.count(parts) in arity do
      parts
      |> Enum.zip(parsers)
      |> parse_csv_elements()
    else
      {:error, :invalid_arity}
    end
  end

  defp parse_csv_elements(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {part, parser}, {:ok, acc} ->
      case parser.(part) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_element}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @doc """
  Parses the value half of an explicit boolean override (`key=false` /
  `key=true`). The bare-flag case (no `=value` at all, meaning `true`) is
  a segment-level concern handled by the caller, not this function — it
  only sees the string after `=` [native §Booleans].

  `key=true` is a specific error, `:true_spelled_bare`, rather than a
  generic invalid value: the bare form is the one spelling of true, and
  the diagnostic should say so.
  """
  @spec flag(String.t()) :: {:ok, boolean()} | {:error, :true_spelled_bare | :invalid_flag}
  def flag("false"), do: {:ok, false}
  def flag("true"), do: {:error, :true_spelled_bare}
  def flag(other) when is_binary(other), do: {:error, :invalid_flag}
end

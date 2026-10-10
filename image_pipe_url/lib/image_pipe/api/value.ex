defmodule ImagePipe.API.Value do
  # Pure parsers for URL option values.
  #
  # Each parses one value shape and returns `{:ok, value}` or
  # `{:error, reason_atom}`. The caller attaches diagnostic spans and validates
  # option-specific ranges and dependencies, such as brightness limits or a
  # dimension's resize consumer.
  @moduledoc false

  alias ImagePipe.Plan.Color, as: PlanColor

  import ImagePipe.Plan.ValueBounds

  @doc """
  Parses a plain decimal: an optional leading `-`, digits, and an optional
  `.digits` fraction. No exponent notation, no leading `+`, no whitespace.

  Returns an integer without a decimal point, otherwise a float.
  The caller checks the option's allowed range.
  """
  @spec number(String.t()) :: {:ok, number()} | {:error, :invalid_number}
  def number(string) when is_binary(string) do
    if number?(string) do
      try do
        {:ok, decimal_to_number(string)}
      rescue
        ArgumentError -> {:error, :invalid_number}
        ArithmeticError -> {:error, :invalid_number}
      end
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
  percentage of the relevant dimension. The absolute value must be at most
  2,147,483,647. Other units, such as `80p`, are rejected.
  """
  @spec length(String.t()) ::
          {:ok, {:px, number()} | {:pct, number()}} | {:error, :invalid_length}
  def length(string) when is_binary(string) do
    case String.split_at(string, byte_size(string) - 3) do
      {numeric_part, "pct"} when numeric_part != "" ->
        parse_length(numeric_part, :pct)

      _no_pct_suffix ->
        parse_length(string, :px)
    end
    |> case do
      {:ok, _value} = ok -> ok
      _invalid -> {:error, :invalid_length}
    end
  end

  defp parse_length(string, unit) do
    case number(string) do
      {:ok, n} when length?(n) -> {:ok, {unit, n}}
      _invalid -> {:error, :invalid_length}
    end
  end

  @doc """
  Parses a target dimension (`w`/`h`): integer pixels from 1 to 2,147,483,647,
  or `auto`.
  Rejects signs, fractions, and `pct` units.
  """
  @spec dimension(String.t()) :: {:ok, pos_integer() | :auto} | {:error, :invalid_dimension}
  def dimension("auto"), do: {:ok, :auto}

  def dimension(string) when is_binary(string) do
    if digits?(string) do
      case String.to_integer(string) do
        n when axis?(n) -> {:ok, n}
        _zero_or_less -> {:error, :invalid_dimension}
      end
    else
      {:error, :invalid_dimension}
    end
  end

  @doc """
  Parses a fraction: a decimal in the inclusive 0.0–1.0 range. Used for
  unitless unit-space values such as `focus`, opacity, intensity, alpha,
  and gradient `start`/`stop`.
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
  Parses a bare 3- or 6-digit hex color (no `#`) or a lowercase CSS Color
  Module Level 4 named color, including aliases such as `cyan`/`aqua` and
  `grey`/`gray`. Expands 3-digit hex first, so `fff` and `ffffff` return the
  same tuple.
  """
  @spec color(String.t()) :: {:ok, {0..255, 0..255, 0..255}} | {:error, :invalid_color}
  def color(string) when is_binary(string) do
    case css_named_color(string) do
      {:ok, rgb} -> {:ok, rgb}
      :error -> parse_hex_color(string)
    end
  end

  # Require lowercase letters before lookup, whose case/hyphen/underscore
  # normalization would otherwise accept names outside the URL grammar.
  defp css_named_color(string) do
    if chars?(string, :lower) do
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
  following standard CSS expansion rules. Each value is an integer from 0 to
  1,000,000,000 pixels.
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
      case padding_pixel(value) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ints} -> {:ok, Enum.reverse(ints)}
      :error -> :error
    end
  end

  defp padding_pixel(value) do
    with true <- digits?(value),
         n when padding?(n) <- String.to_integer(value) do
      {:ok, n}
    else
      _invalid -> :error
    end
  end

  @doc """
  Parses a comma-separated list of fixed-arity-range positional values,
  applying one parser per position. `arity` is the inclusive range of accepted
  element counts; `parsers` supplies one parser per position, up to the maximum
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
  only sees the string after `=`.

  `key=true` is a specific error, `:true_spelled_bare`, rather than a
  generic invalid value: the bare form is the one spelling of true, and
  the diagnostic should say so.
  """
  @spec flag(String.t()) :: {:ok, boolean()} | {:error, :true_spelled_bare | :invalid_flag}
  def flag("false"), do: {:ok, false}
  def flag("true"), do: {:error, :true_spelled_bare}
  def flag(other) when is_binary(other), do: {:error, :invalid_flag}

  # Grammar checks scan bytes: OTP 28 and later rebuild a regex attribute at
  # every use.

  # `-?[0-9]+(\.[0-9]+)?`
  defp number?("-" <> rest), do: unsigned_number?(rest)
  defp number?(string), do: unsigned_number?(string)

  defp unsigned_number?(string) do
    case :binary.split(string, ".") do
      [whole] -> digits?(whole)
      [whole, fraction] -> digits?(whole) and digits?(fraction)
    end
  end

  defp digits?(string), do: chars?(string, :digit)

  # One or more bytes of `class`.
  defp chars?(<<char, rest::binary>>, class),
    do: char?(char, class) and (rest == "" or chars?(rest, class))

  defp chars?(_empty, _class), do: false

  defp char?(char, :digit), do: char in ?0..?9
  defp char?(char, :lower), do: char in ?a..?z
end

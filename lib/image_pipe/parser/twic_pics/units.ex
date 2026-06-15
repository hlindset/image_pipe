defmodule ImagePipe.Parser.TwicPics.Units do
  @moduledoc false

  @type measure :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}

  # TwicPics lengths have only two unit suffixes: `p` (percent) and `s` (scale).
  # Pixels are bare numbers — there is NO `px` unit. A `px` substring only ever
  # appears inside a Size/Coordinates token (e.g. `10px150`), where the caller
  # splits on `x` first (`10p` × `150` = 10% × 150px), so a length parser never
  # receives a `px`-suffixed token from real input. Percent/scale suffixes are
  # converted to an exact `{:ratio, n, d}` from the string form (no float
  # rounding): percent divides by 100, scale is the raw fraction.

  # Dimension length: strictly positive.
  @spec dimension_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def dimension_length(value), do: parse_length(value, :positive)

  # Position length: zero-based, non-negative.
  @spec position_length(String.t()) :: {:ok, measure()} | {:error, term()}
  def position_length(value), do: parse_length(value, :non_negative)

  defp parse_length("-" <> _ = value, _sign), do: {:error, {:invalid_length, value}}

  defp parse_length(value, sign) when is_binary(value) do
    cond do
      String.ends_with?(value, "p") ->
        to_ratio(String.trim_trailing(value, "p"), 100, sign, value)

      String.ends_with?(value, "s") ->
        to_ratio(String.trim_trailing(value, "s"), 1, sign, value)

      true ->
        to_pixels_measure(value, sign)
    end
  end

  defp to_pixels_measure(value, sign) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, {:px, n}}
      {0, ""} when sign == :non_negative -> {:ok, {:px, 0}}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  # decimal_term parses a strictly-positive decimal into {integer, exponent}.
  # For positions we also accept "0"/"0.0" as {0, 0}.
  defp to_ratio(decimal, unit_denominator, sign, raw) do
    case decimal_measure(decimal, sign) do
      {:ok, {n, exp}} ->
        denominator = unit_denominator * Integer.pow(10, exp)
        gcd = max(1, Integer.gcd(n, denominator))
        {:ok, {:ratio, div(n, gcd), div(denominator, gcd)}}

      :error ->
        {:error, {:invalid_length, raw}}
    end
  end

  defp decimal_measure(decimal, sign) do
    case decimal_term(decimal) do
      {:ok, term} -> {:ok, term}
      :error when sign == :non_negative -> zero_decimal(decimal)
      :error -> :error
    end
  end

  defp zero_decimal(decimal) do
    case Float.parse(decimal) do
      {+0.0, ""} ->
        {:ok, {0, 0}}

      _ ->
        case Integer.parse(decimal) do
          {0, ""} -> {:ok, {0, 0}}
          _ -> :error
        end
    end
  end

  @spec size(String.t()) :: {:ok, {measure() | :auto, measure() | :auto}} | {:error, term()}
  def size(value), do: pair(value, :auto)

  @spec crop_size(String.t()) ::
          {:ok, {measure() | :full_axis, measure() | :full_axis}} | {:error, term()}
  def crop_size(value), do: pair(value, :full_axis)

  defp pair(value, omitted) do
    case String.split(value, "x", parts: 2) do
      [single] ->
        with {:ok, w} <- dimension(single, omitted), do: {:ok, {w, omitted}}

      [w, h] ->
        with {:ok, w} <- dimension(w, omitted),
             {:ok, h} <- dimension(h, omitted) do
          {:ok, {w, h}}
        end
    end
  end

  defp dimension("-", omitted), do: {:ok, omitted}
  defp dimension("", omitted), do: {:ok, omitted}
  defp dimension(value, _omitted), do: dimension_length(value)

  # Ratios accept two strictly-positive numbers — integer or decimal, e.g. `16:9`
  # or `1.5:2`. Each term is scaled to an integer by its number of fractional
  # digits (exact, from the string form — no float rounding), brought to a common
  # power of ten, then reduced to a `{:ratio, n, d}` of positive integers (so it
  # maps cleanly onto the integer aspect-ratio the crop operation expects).
  @spec ratio(String.t()) :: {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, term()}
  def ratio(value) do
    with [w, h] <- String.split(value, ":", parts: 2),
         {:ok, {nw, ew}} <- decimal_term(w),
         {:ok, {nh, eh}} <- decimal_term(h) do
      exp = max(ew, eh)
      numerator = nw * Integer.pow(10, exp - ew)
      denominator = nh * Integer.pow(10, exp - eh)
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    else
      _ -> {:error, {:invalid_ratio, value}}
    end
  end

  # Parse a strictly-positive decimal into `{integer, exponent}` such that the
  # value equals `integer × 10^-exponent` (e.g. `"1.5"` → `{15, 1}`, `"16"` →
  # `{16, 0}`, `".5"` → `{5, 1}`). Rejects zero, negatives, and non-numerics.
  defp decimal_term(term) do
    case String.split(term, ".") do
      [whole] -> scaled_integer(whole, "")
      [whole, frac] -> scaled_integer(whole, frac)
      _ -> :error
    end
  end

  defp scaled_integer(whole, frac) do
    case Integer.parse(whole <> frac) do
      {n, ""} when n > 0 -> {:ok, {n, byte_size(frac)}}
      _ -> :error
    end
  end

  @spec coordinates(String.t()) :: {:ok, {measure(), measure()}} | {:error, term()}
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- position_length(x),
         {:ok, y} <- position_length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end

  @anchors %{
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center},
    "top-left" => {:anchor, :left, :top},
    "top-right" => {:anchor, :right, :top},
    "bottom-left" => {:anchor, :left, :bottom},
    "bottom-right" => {:anchor, :right, :bottom}
  }

  @spec anchor(String.t()) :: {:ok, {:anchor, atom(), atom()}} | {:error, term()}
  def anchor(value) do
    case Map.fetch(@anchors, value) do
      {:ok, guide} -> {:ok, guide}
      :error -> {:error, {:invalid_anchor, value}}
    end
  end
end

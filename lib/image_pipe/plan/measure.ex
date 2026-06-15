defmodule ImagePipe.Plan.Measure do
  @moduledoc """
  Canonical coordinate/unit vocabulary for the product-neutral Plan.

  A measure is either absolute pixels (`{:px, n}`) or an exact rational fraction
  of a reference dimension (`{:ratio, n, d}`). Dialect sugar (`percent`, `scale`)
  is converted here into the exact ratio form. Resolution of a measure against a
  running dimension happens in the transform boundary, not here.
  """

  @type t :: {:px, integer()} | {:ratio, integer(), pos_integer()}

  @doc "Convert a percentage (`50` → 1/2) to an exact ratio. Non-negative only."
  @spec from_percent(number()) :: {:ok, t()} | {:error, :measure}
  def from_percent(value) when is_integer(value) and value >= 0,
    do: reduce(value, 100)

  def from_percent(value) when is_float(value) and value >= 0.0 do
    with {:ok, {num, den}} <- decimal_fraction(value), do: reduce(num, den * 100)
  end

  def from_percent(_value), do: {:error, :measure}

  @doc "Convert a scale factor (`0.5` → 1/2, `2` → 2/1) to an exact ratio. Non-negative only."
  @spec from_scale(number()) :: {:ok, t()} | {:error, :measure}
  def from_scale(value) when is_integer(value) and value >= 0,
    do: reduce(value, 1)

  def from_scale(value) when is_float(value) and value >= 0.0 do
    with {:ok, {num, den}} <- decimal_fraction(value), do: reduce(num, den)
  end

  def from_scale(_value), do: {:error, :measure}

  @doc "Validate a measure in the *dimension* role (extent — strictly positive)."
  @spec dimension(term()) :: {:ok, t()} | {:error, :dimension}
  def dimension({:px, value}) when is_integer(value) and value > 0, do: {:ok, {:px, value}}

  def dimension({:ratio, num, den})
      when is_integer(num) and is_integer(den) and num > 0 and den > 0,
      do: {:ok, {:ratio, num, den}}

  def dimension(_measure), do: {:error, :dimension}

  @doc "Validate a measure in the *position* role (coordinate — zero-based, non-negative)."
  @spec position(term()) :: {:ok, t()} | {:error, :position}
  def position({:px, value}) when is_integer(value) and value >= 0, do: {:ok, {:px, value}}

  def position({:ratio, num, den})
      when is_integer(num) and is_integer(den) and num >= 0 and den > 0,
      do: {:ok, {:ratio, num, den}}

  def position(_measure), do: {:error, :position}

  # Exact decimal -> {numerator, denominator} via the 7-decimal string form,
  # mirroring operation.ex resize_dpr (no float rounding error).
  defp decimal_fraction(value) do
    value
    |> Float.round(7)
    |> :erlang.float_to_binary(decimals: 7)
    |> String.split(".", parts: 2)
    |> case do
      [whole, frac] ->
        digits = whole <> frac
        {:ok, {String.to_integer(digits), Integer.pow(10, byte_size(frac))}}

      [whole] ->
        {:ok, {String.to_integer(whole), 1}}
    end
  end

  defp reduce(num, den) do
    gcd = Integer.gcd(num, den)
    {:ok, {:ratio, div(num, gcd), div(den, gcd)}}
  end
end

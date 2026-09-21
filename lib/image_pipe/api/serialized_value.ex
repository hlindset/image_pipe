defmodule ImagePipe.API.SerializedValue do
  @moduledoc false

  def csv(values), do: Enum.map_join(values, ",", &scalar/1)

  def color({r, g, b}), do: Base.encode16(<<r, g, b>>, case: :lower)

  def scalar(value) when is_binary(value), do: value
  def scalar(value) when is_integer(value), do: Integer.to_string(value)
  def scalar(value) when is_float(value), do: decimal(value)
  def scalar({:px, value}), do: scalar(value)
  def scalar({:pct, value}), do: scalar(value) <> "pct"
  def scalar({:convert, profile}), do: scalar(profile)
  def scalar(:jpeg_xl), do: "jxl"
  def scalar(:preserve_source), do: "preserve"
  def scalar(:tone_map), do: "tonemap"
  def scalar(:horizontal), do: "h"
  def scalar(:vertical), do: "v"
  def scalar(:both), do: "hv"
  def scalar(value) when is_atom(value), do: value |> Atom.to_string() |> String.replace("_", "-")

  # The grammar accepts plain decimals. Expand the shortest round-trippable
  # float representation rather than rounding small values to a fixed precision.
  defp decimal(value) when value == 0, do: "0"
  defp decimal(value) when value < 0, do: "-" <> decimal(-value)

  defp decimal(value) do
    case String.split(Float.to_string(value), "e") do
      [decimal] -> String.replace_suffix(decimal, ".0", "")
      [mantissa, exponent] -> expand(mantissa, String.to_integer(exponent))
    end
  end

  defp expand(mantissa, exponent) do
    [whole, fraction] = String.split(mantissa, ".")
    digits = whole <> fraction
    point = byte_size(whole) + exponent

    cond do
      point <= 0 ->
        "0." <> String.duplicate("0", -point) <> digits

      point >= byte_size(digits) ->
        digits <> String.duplicate("0", point - byte_size(digits))

      true ->
        {whole, fraction} = String.split_at(digits, point)
        whole <> "." <> fraction
    end
  end
end

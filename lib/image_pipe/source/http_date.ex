defmodule ImagePipe.Source.HTTPDate do
  @moduledoc false

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
          |> Enum.with_index(1)
          |> Map.new()

  @standard ~r/\A[a-z]+, (\d{2})[ -]([a-z]{3})[ -](\d{2}|\d{4}) (\d{2}):(\d{2}):(\d{2}) gmt\z/
  @asctime ~r/\A[a-z]{3} ([a-z]{3}) {1,2}(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})\z/

  def parse(value, now) do
    value = String.downcase(value)

    case Regex.run(@standard, value, capture: :all_but_first) do
      [day, month, year, hour, minute, second] ->
        timestamp(year, month, day, hour, minute, second, now)

      nil ->
        parse_asctime(value, now)
    end
  end

  defp parse_asctime(value, now) do
    case Regex.run(@asctime, value, capture: :all_but_first) do
      [month, day, hour, minute, second, year] ->
        timestamp(year, month, day, hour, minute, second, now)

      nil ->
        :error
    end
  end

  defp timestamp(year, month, day, hour, minute, second, now) do
    with {:ok, month} <- Map.fetch(@months, month),
         {:ok, date} <- Date.new(year(year, now), month, String.to_integer(day)),
         {:ok, time} <-
           Time.new(String.to_integer(hour), String.to_integer(minute), String.to_integer(second)),
         {:ok, datetime} <- DateTime.new(date, time) do
      {:ok, DateTime.to_unix(datetime)}
    else
      _invalid -> :error
    end
  end

  # RFC 9110: a two-digit year more than 50 years ahead means the prior century.
  defp year(<<_, _>> = year, now) do
    current = DateTime.from_unix!(now).year
    candidate = div(current, 100) * 100 + String.to_integer(year)

    case candidate > current + 50 do
      true -> candidate - 100
      false -> candidate
    end
  end

  defp year(year, _now), do: String.to_integer(year)
end

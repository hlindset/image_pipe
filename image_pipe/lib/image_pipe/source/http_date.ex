defmodule ImagePipe.Source.HTTPDate do
  @moduledoc false

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)
          |> Enum.with_index(1)
          |> Map.new()

  # The IMF-fixdate and RFC 850 forms share one shape:
  # `[a-z]+, DD[ -]mon[ -](YY|YYYY) HH:MM:SS gmt`, and asctime is
  # `[a-z]{3} mon {1,2}D{1,2} HH:MM:SS YYYY`. Matched on bytes because OTP 28
  # and later rebuild a regex at every use. Dates are ASCII, so they're
  # lowercased with ASCII rules.
  def parse(value, now) do
    value = String.downcase(value, :ascii)

    case standard(value) do
      {day, month, year, hour, minute, second} ->
        timestamp(year, month, day, hour, minute, second, now)

      :error ->
        parse_asctime(value, now)
    end
  end

  defp parse_asctime(value, now) do
    case asctime(value) do
      {month, day, hour, minute, second, year} ->
        timestamp(year, month, day, hour, minute, second, now)

      :error ->
        :error
    end
  end

  defp standard(value) do
    with {:ok, <<", ", day::binary-size(2), sep1, month::binary-size(3), sep2, rest::binary>>} <-
           after_weekday(value),
         true <- digits?(day) and sep1 in [?\s, ?-] and sep2 in [?\s, ?-] and letters?(month),
         {year, " " <> clock} <- standard_year(rest),
         {hour, minute, second, " gmt"} <- clock(clock) do
      {day, month, year, hour, minute, second}
    else
      _no_match -> :error
    end
  end

  # `[a-z]+` before the comma.
  defp after_weekday(<<char, rest::binary>>) when char in ?a..?z, do: {:ok, skip_letters(rest)}
  defp after_weekday(_value), do: :error

  defp skip_letters(<<char, rest::binary>>) when char in ?a..?z, do: skip_letters(rest)
  defp skip_letters(rest), do: rest

  defp standard_year(<<year::binary-size(4), " ", _::binary>> = rest) do
    if digits?(year),
      do: {year, binary_part(rest, 4, byte_size(rest) - 4)},
      else: two_digit_year(rest)
  end

  defp standard_year(rest), do: two_digit_year(rest)

  defp two_digit_year(<<year::binary-size(2), rest::binary>>) do
    if digits?(year), do: {year, rest}, else: :error
  end

  defp two_digit_year(_rest), do: :error

  defp asctime(<<weekday::binary-size(3), " ", month::binary-size(3), " ", rest::binary>>) do
    rest = with " " <> unpadded <- rest, do: unpadded

    with true <- letters?(weekday) and letters?(month),
         {day, " " <> clock} <- asctime_day(rest),
         {hour, minute, second, " " <> year} <- clock(clock),
         true <- byte_size(year) == 4 and digits?(year) do
      {month, day, hour, minute, second, year}
    else
      _no_match -> :error
    end
  end

  defp asctime(_value), do: :error

  defp asctime_day(<<day::binary-size(2), " ", _::binary>> = rest) do
    if digits?(day),
      do: {day, binary_part(rest, 2, byte_size(rest) - 2)},
      else: one_digit_day(rest)
  end

  defp asctime_day(rest), do: one_digit_day(rest)

  defp one_digit_day(<<day, rest::binary>>) when day in ?0..?9, do: {<<day>>, rest}
  defp one_digit_day(_rest), do: :error

  # `HH:MM:SS`, returning what follows.
  defp clock(
         <<hour::binary-size(2), ?:, minute::binary-size(2), ?:, second::binary-size(2),
           rest::binary>>
       ) do
    if digits?(hour) and digits?(minute) and digits?(second),
      do: {hour, minute, second, rest},
      else: :error
  end

  defp clock(_rest), do: :error

  defp digits?(<<char, rest::binary>>) when char in ?0..?9, do: rest == "" or digits?(rest)
  defp digits?(_value), do: false

  defp letters?(<<char, rest::binary>>) when char in ?a..?z, do: rest == "" or letters?(rest)
  defp letters?(_value), do: false

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

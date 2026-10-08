defmodule ImagePipe.Source.HTTPDatePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Source.HTTPDate

  @now 1_791_454_000

  # The regex grammar `HTTPDate.parse/2` must keep accepting exactly.
  defmodule Reference do
    @moduledoc false
    @months ~w(jan feb mar apr may jun jul aug sep oct nov dec) |> Enum.with_index(1) |> Map.new()
    @standard ~r/\A[a-z]+, (\d{2})[ -]([a-z]{3})[ -](\d{2}|\d{4}) (\d{2}):(\d{2}):(\d{2}) gmt\z/
    @asctime ~r/\A[a-z]{3} ([a-z]{3}) {1,2}(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})\z/

    def parse(value, now) do
      value = String.downcase(value)

      case Regex.run(@standard, value, capture: :all_but_first) do
        [day, month, year, hour, minute, second] ->
          timestamp(year, month, day, hour, minute, second, now)

        nil ->
          case Regex.run(@asctime, value, capture: :all_but_first) do
            [month, day, hour, minute, second, year] ->
              timestamp(year, month, day, hour, minute, second, now)

            nil ->
              :error
          end
      end
    end

    defp timestamp(year, month, day, hour, minute, second, now) do
      with {:ok, month} <- Map.fetch(@months, month),
           {:ok, date} <- Date.new(year(year, now), month, String.to_integer(day)),
           {:ok, time} <-
             Time.new(
               String.to_integer(hour),
               String.to_integer(minute),
               String.to_integer(second)
             ),
           {:ok, datetime} <- DateTime.new(date, time) do
        {:ok, DateTime.to_unix(datetime)}
      else
        _invalid -> :error
      end
    end

    defp year(<<_, _>> = year, now) do
      current = DateTime.from_unix!(now).year
      candidate = div(current, 100) * 100 + String.to_integer(year)
      if candidate > current + 50, do: candidate - 100, else: candidate
    end

    defp year(year, _now), do: String.to_integer(year)
  end

  defp part(options), do: member_of(options)

  defp standard do
    gen all weekday <- part(["Thu", "thursday", "", "T1", "Mon"]),
            comma <- part([", ", ",", " , "]),
            day <- part(["08", "8", "31", "32", "0a"]),
            sep1 <- part([" ", "-", "  ", "/"]),
            month <- part(["Oct", "oct", "OCT", "Foo", "Octo"]),
            sep2 <- part([" ", "-", "/"]),
            year <- part(["2026", "26", "99", "126", "20266"]),
            time <- part(["10:00:00", "23:59:60", "1:00:00", "10:0:00", "25:00:00"]),
            zone <- part([" GMT", " gmt", " UTC", "GMT", " GMT "]) do
      "#{weekday}#{comma}#{day}#{sep1}#{month}#{sep2}#{year} #{time}#{zone}"
    end
  end

  defp asctime do
    gen all weekday <- part(["Thu", "thu", "Th", "Thur"]),
            month <- part(["Oct", "Feb", "Fob"]),
            space <- part([" ", "  ", "   "]),
            day <- part(["8", "08", "29", "30", "123", ""]),
            time <- part(["10:00:00", "1:00:00", "10:00"]),
            year <- part(["2026", "2024", "26", "20266"]),
            gap <- part([" ", "  "]) do
      "#{weekday} #{month}#{space}#{day} #{time}#{gap}#{year}"
    end
  end

  property "accepts exactly what the regex grammar accepts" do
    check all value <-
                one_of([
                  standard(),
                  asctime(),
                  string(Enum.concat([?0..?9, ?a..?z, [?\s, ?:, ?,, ?-]]), max_length: 30)
                ]),
              max_runs: 2_000 do
      assert HTTPDate.parse(value, @now) == Reference.parse(value, @now), inspect(value)
    end
  end
end

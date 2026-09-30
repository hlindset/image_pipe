defmodule ImagePipe.Cache.EntryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.Entry

  property "entry stores only lowercase allowlisted headers" do
    check all headers <- list_of(header(), max_length: 30),
              max_runs: 100 do
      {:ok, cached_headers} = Entry.cacheable_headers(headers)

      assert Enum.all?(cached_headers, fn {name, _value} -> name in ["vary", "cache-control"] end)
      assert Enum.all?(cached_headers, fn {name, _value} -> name == String.downcase(name) end)
    end
  end

  property "allowed headers preserve relative input order" do
    check all headers <- list_of(header(), max_length: 30),
              max_runs: 100 do
      {:ok, cached_headers} = Entry.cacheable_headers(headers)

      expected =
        headers
        |> Enum.flat_map(fn {name, value} ->
          normalized_name = String.downcase(name)

          if normalized_name in ["vary", "cache-control"] do
            [{normalized_name, value}]
          else
            []
          end
        end)

      assert cached_headers == expected
    end
  end

  defp header do
    map({header_name(), header_value()}, fn {name, value} -> {name, value} end)
  end

  defp header_name do
    one_of([
      member_of(["vary", "Vary", "VARY", "cache-control", "Cache-Control", "CACHE-CONTROL"]),
      valid_disallowed_header_name()
    ])
  end

  defp valid_disallowed_header_name do
    map(
      {member_of(["x-test", "x-cache", "content-type", "etag", "last-modified"]),
       string(:alphanumeric, max_length: 8)},
      fn {prefix, suffix} ->
        if suffix == "" do
          prefix
        else
          prefix <> "-" <> suffix
        end
      end
    )
  end

  defp header_value, do: string(:alphanumeric, max_length: 24)
end

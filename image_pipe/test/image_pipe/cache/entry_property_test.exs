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

  # The patterns the scans replaced, kept as the reference.
  @header_name_pattern ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
  @header_value_pattern ~r/\A[^\x00-\x1F\x7F]*\z/
  @content_type_pattern ~r{\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+/[!#$%&'*+\-.^_`|~0-9A-Za-z]+( *;[^\x00-\x1F\x7F]*)?\z}

  property "header names and values are accepted exactly when they are tokens and control-free" do
    check all name <- header_bytes(),
              value <- header_bytes(),
              max_runs: 500 do
      expected =
        Regex.match?(@header_name_pattern, name) and Regex.match?(@header_value_pattern, value)

      assert match?({:ok, _}, Entry.cacheable_headers([{name, value}])) == expected
    end
  end

  property "a content type is accepted exactly when it is type/subtype with optional parameters" do
    check all content_type <- header_bytes(), max_runs: 500 do
      accepted? =
        Entry.validate_content_type(content_type, {:complete_body, content_type}) == :ok

      assert accepted? == Regex.match?(@content_type_pattern, content_type)
    end
  end

  # Token characters, the separators that matter to these grammars, control
  # bytes and a multi-byte character, so every branch is reached often.
  defp header_bytes do
    [?a, ?Z, ?0, ?-, ?!, ?~, ?/, ?;, ?\s, ?=, ?", ?\t, ?\n, 0, 0x7F, ?:]
    |> Enum.map(&constant(<<&1>>))
    |> Kernel.++([constant("é"), constant("text"), constant("image/webp")])
    |> one_of()
    |> list_of(max_length: 12)
    |> map(&Enum.join/1)
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

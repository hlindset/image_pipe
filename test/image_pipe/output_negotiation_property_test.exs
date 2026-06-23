defmodule ImagePipe.Output.NegotiationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Output.Negotiation

  property "modern candidates match enabled modern formats accepted by the header" do
    check all accept_header <- accept_header(),
              auto_jpeg_xl? <- boolean(),
              auto_avif? <- boolean(),
              auto_webp? <- boolean(),
              max_runs: 100 do
      opts = [
        auto_jpeg_xl: auto_jpeg_xl?,
        auto_avif: auto_avif?,
        auto_webp: auto_webp?,
        output_capabilities: %{jpeg_xl: true, avif: true, webp: true}
      ]

      assert Negotiation.modern_candidates(accept_header, opts) ==
               expected_modern_candidates(accept_header, opts)
    end
  end

  property "modern candidates are always returned in server-preference order" do
    check all accept_header <- accept_header(),
              opts <-
                map({boolean(), boolean(), boolean()}, fn {auto_jpeg_xl?, auto_avif?, auto_webp?} ->
                  [
                    auto_jpeg_xl: auto_jpeg_xl?,
                    auto_avif: auto_avif?,
                    auto_webp: auto_webp?,
                    output_capabilities: %{jpeg_xl: true, avif: true, webp: true}
                  ]
                end),
              max_runs: 100 do
      candidates = Negotiation.modern_candidates(accept_header, opts)

      assert candidates in [
               [],
               [:jpeg_xl],
               [:avif],
               [:webp],
               [:jpeg_xl, :avif],
               [:jpeg_xl, :webp],
               [:avif, :webp],
               [:jpeg_xl, :avif, :webp]
             ]
    end
  end

  defp expected_modern_candidates(accept_header, opts) do
    entries = parse_accept(accept_header)

    []
    |> maybe_append_modern(Keyword.get(opts, :auto_jpeg_xl, true), :jpeg_xl, "image/jxl", entries)
    |> maybe_append_modern(Keyword.get(opts, :auto_avif, true), :avif, "image/avif", entries)
    |> maybe_append_modern(Keyword.get(opts, :auto_webp, true), :webp, "image/webp", entries)
  end

  defp maybe_append_modern(candidates, false, _format, _mime_type, _entries), do: candidates
  defp maybe_append_modern(candidates, true, _format, _mime_type, []), do: candidates

  defp maybe_append_modern(candidates, true, format, mime_type, entries) do
    if acceptable?(mime_type, entries), do: candidates ++ [format], else: candidates
  end

  defp acceptable?(mime_type, entries) do
    entries
    |> matching_qualities(mime_type)
    |> case do
      [] -> false
      qualities -> Enum.any?(qualities, &(&1 > 0)) and not Enum.any?(qualities, &(&1 == 0))
    end
  end

  defp matching_qualities(entries, mime_type) do
    entries
    |> Enum.group_by(fn {accepted, _quality} -> match_specificity(accepted, mime_type) end)
    |> qualities_for_best_specificity()
  end

  defp qualities_for_best_specificity(qualities_by_specificity) do
    Enum.find_value([:exact, :image], [], fn specificity ->
      quality_values(qualities_by_specificity, specificity)
    end)
  end

  defp quality_values(qualities_by_specificity, specificity) do
    qualities =
      qualities_by_specificity
      |> Map.get(specificity, [])
      |> Enum.map(fn {_accepted, quality} -> quality end)

    if qualities == [], do: nil, else: qualities
  end

  defp match_specificity(accepted, mime_type) do
    cond do
      canonical_mime_type(accepted) == mime_type -> :exact
      accepted == "image/*" -> :image
      true -> :none
    end
  end

  defp parse_accept(""), do: []

  defp parse_accept(accept_header) do
    accept_header
    |> String.split(",")
    |> Enum.map(&parse_accept_entry/1)
  end

  defp parse_accept_entry(entry) do
    [media_range | params] = String.split(entry, ";")
    quality = Enum.find_value(params, 1.0, &quality_param/1)

    {String.downcase(media_range), quality}
  end

  defp quality_param(param) do
    case String.split(param, "=", parts: 2) do
      ["q", value] -> String.to_float(value)
      _other -> nil
    end
  end

  defp canonical_mime_type("image/jpg"), do: "image/jpeg"
  defp canonical_mime_type(mime_type), do: mime_type

  defp accept_header do
    one_of([
      constant(""),
      map(list_of(media_range_with_optional_quality(), min_length: 1, max_length: 5), fn ranges ->
        Enum.join(ranges, ",")
      end)
    ])
  end

  # Only well-formed in-range weights: this property pins order/preference
  # invariants over valid input. Malformed weights (`q=1.5`, `q=abc`) are covered
  # by the example suite — don't add them here, the oracle's `String.to_float/1`
  # would raise on them.
  defp media_range_with_optional_quality do
    one_of([
      media_range(),
      map({media_range(), integer(0..10)}, fn {range, q} -> "#{range};q=#{q / 10}" end)
    ])
  end

  defp media_range do
    member_of([
      "image/jxl",
      "image/avif",
      "image/webp",
      "image/jpeg",
      "image/png",
      "image/gif",
      "application/json",
      "image/*",
      "*/*"
    ])
  end
end

defmodule ImagePipe.Format.Detector do
  @moduledoc false

  @type detected() ::
          :jpeg
          | :png
          | :webp
          | :gif
          | :bmp
          | :ico
          | :svg
          | :tiff
          | :heif
          | :avif
          | :jpeg_xl
          | :jpeg2000
          | :unknown

  # A signature is a list of (byte | :any); :any matches any single byte.
  # First matching signature across the ordered table wins. Signatures are
  # mutually exclusive across formats, so order is for determinism only.
  @ftyp_prefix [:any, :any, :any, :any, ?f, ?t, ?y, ?p]
  @heif_brands [~c"heic", ~c"heix", ~c"hevc", ~c"heim", ~c"heis", ~c"hevm", ~c"hevs", ~c"mif1"]

  @magic [
    {:png, [[0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A]]},
    {:jpeg, [[0xFF, 0xD8]]},
    {:gif, [[?G, ?I, ?F, ?8, :any, ?a]]},
    {:bmp, [[?B, ?M]]},
    {:ico, [[0x00, 0x00, 0x01, 0x00]]},
    {:webp, [[?R, ?I, ?F, ?F, :any, :any, :any, :any, ?W, ?E, ?B, ?P]]},
    {:jpeg_xl,
     [
       [0xFF, 0x0A],
       [0x00, 0x00, 0x00, 0x0C, ?J, ?X, ?L, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
     ]},
    {:jpeg2000,
     [
       [0x00, 0x00, 0x00, 0x0C, ?j, ?P, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A],
       [0xFF, 0x4F, 0xFF, 0x51]
     ]},
    {:avif, [@ftyp_prefix ++ ~c"avif"]},
    {:heif, Enum.map(@heif_brands, &(@ftyp_prefix ++ &1))},
    {:tiff, [[?I, ?I, 0x2A, 0x00], [?M, ?M, 0x00, 0x2A]]}
  ]

  @doc """
  Classify the source image format from a bounded header peek.

  Magic-byte detection first (first match wins); if no signature matches, a
  lightweight SVG structural scan; otherwise `:unknown`. Detection is advisory
  for gating and authoritative-where-confident — never a full decode.
  """
  @spec detect(binary()) :: detected()
  def detect(peek) when is_binary(peek) do
    case match_magic(peek) do
      nil -> if svg?(peek), do: :svg, else: :unknown
      format -> format
    end
  end

  defp match_magic(peek) do
    Enum.find_value(@magic, fn {format, signatures} ->
      if Enum.any?(signatures, &signature_match?(peek, &1)), do: format
    end)
  end

  defp signature_match?(peek, signature) do
    byte_size(peek) >= length(signature) and prefix_match?(peek, signature)
  end

  defp prefix_match?(_peek, []), do: true

  defp prefix_match?(<<byte, rest::binary>>, [expected | tail]) do
    (expected == :any or expected == byte) and prefix_match?(rest, tail)
  end

  # --- SVG structural scan ---
  #
  # Bounded, not a full XML parser. Skip a UTF-8 BOM, leading whitespace, and the
  # XML prolog (declarations / comments / DOCTYPE incl. a `[ ... ]` internal
  # subset), then test for an `<svg>` root element (optionally namespace-prefixed).
  # Biases toward catching real SVGs so libvips' svgload never parses attacker
  # XML; punts to a non-match (=> :unknown) on anything ambiguous. A non-match is
  # harmless: it falls through to libvips, which still rejects SVG.

  defp svg?(peek) do
    peek
    |> strip_bom()
    |> skip_prolog()
    |> svg_root?()
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp skip_prolog(bin) do
    case skip_ws(bin) do
      <<"<?", rest::binary>> -> rest |> skip_after("?>") |> skip_prolog()
      <<"<!--", rest::binary>> -> rest |> skip_after("-->") |> skip_prolog()
      <<"<!", rest::binary>> -> rest |> skip_doctype() |> skip_prolog()
      other -> other
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  # The suffix after the first occurrence of `terminator`, or "" if it is not
  # present within the peek (treated as "not enough data" => not SVG).
  defp skip_after(bin, terminator) do
    case :binary.split(bin, terminator) do
      [_before, rest] -> rest
      [_whole] -> ""
    end
  end

  # Positioned just after "<!". Skip to the matching top-level ">", stepping over
  # a "[ ... ]" internal subset (which may itself contain ">").
  defp skip_doctype(<<>>), do: ""
  defp skip_doctype(<<?>, rest::binary>>), do: rest
  defp skip_doctype(<<?[, rest::binary>>), do: rest |> skip_after("]") |> skip_doctype()
  defp skip_doctype(<<_c, rest::binary>>), do: skip_doctype(rest)

  defp svg_root?(<<?<, rest::binary>>), do: local_name(read_name(rest)) == "svg"
  defp svg_root?(_bin), do: false

  # Read an element name up to a name terminator (whitespace, ">", "/", or EOF).
  defp read_name(bin), do: read_name(bin, [])

  defp read_name(<<c, _rest::binary>> = bin, acc) when c in [?\s, ?\t, ?\r, ?\n, ?>, ?/],
    do: {finish_name(acc), bin}

  defp read_name(<<c, rest::binary>>, acc), do: read_name(rest, [c | acc])
  defp read_name(<<>>, acc), do: {finish_name(acc), <<>>}

  defp finish_name(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Strip an optional `prefix:` so a namespace-prefixed root resolves to its local
  # name (imgproxy matches on `Name.Local() == "svg"`).
  defp local_name({name, _rest}) do
    case :binary.split(name, ":") do
      [_prefix, local] -> local
      [local] -> local
    end
  end
end

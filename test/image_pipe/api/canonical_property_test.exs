defmodule ImagePipe.API.CanonicalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.API.Parser

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp parse(segments), do: Parser.parse(lexed(segments), [])

  # A representative, mutually-compatible group: a concrete resize with a
  # cover-family fit (so anchor is a satisfied guide consumer), plus one
  # instance of every other group-scoped shape in the probe subset. No
  # Tier-3 exclusive pair (crop/region, anchor/focus) is present, so every
  # permutation of this segment list is independently valid.
  @fixed_group_segments [
    "w=300",
    "h=400",
    "min-w=200",
    "min-h=250",
    "fit=cover",
    "zoom=1.25,0.75",
    "dpr=2",
    "crop=600,400",
    "crop-ratio=3:2",
    "crop-ratio-enlarge",
    "anchor=top-left",
    "anchor-offset=10,-20pct",
    "blur=2.5",
    "sharpen=1.5",
    "pixelate=8",
    "monochrome=0.5,red",
    "duotone=0.75,black,white",
    "brightness=-20",
    "contrast=1.25",
    "saturation=0.75",
    "colorize=0.5,blue,keep-alpha",
    "gradient=1,red,left,0.25,0.75",
    "pad=10,20,30,40",
    "bg=fff,0.5",
    "trim=auto",
    "trim-symmetry=hv",
    "extend",
    "extend-at=bottom-right",
    "extend-offset=-5,10pct"
  ]

  describe "order-insensitivity within a group [API §Canonical form and identity]" do
    property "any permutation of a group's segments yields an equal %Request{}" do
      assert {:ok, canonical} = parse(@fixed_group_segments)

      check all permutation <- permutation_of(@fixed_group_segments) do
        assert {:ok, ^canonical} = parse(permutation)
      end
    end
  end

  defp permutation_of(list) do
    StreamData.uniq_list_of(StreamData.member_of(list),
      length: length(list),
      max_tries: 500
    )
  end

  # Several independently mutually-compatible bases, chosen to vary group
  # shape (guide via crop vs. cover-fit, region instead of crop, a
  # request-scoped output/format/q spread, an enlarge flag) so the
  # stability property below isn't pinned to one URL's happenstance
  # ordering — it must hold across genuinely varied inputs.
  @stability_bases [
    ["w=300", "h=400", "fit=cover", "anchor=smart", "blur=2.5", "pad=10,20,30,40"],
    [
      "w=300",
      "h=400",
      "extend-ratio",
      "extend-at=bottom-right",
      "extend-offset=10,-20pct"
    ],
    [
      "crop=600,400",
      "crop-ratio=3:2",
      "crop-ratio-enlarge",
      "anchor=top-left",
      "trim=fff,10",
      "trim-symmetry=h"
    ],
    ["crop=600,400", "detect=face:3,car"],
    [
      "sharpen=1.5",
      "pixelate=8",
      "monochrome=0.5,red",
      "duotone=0.75,black,white",
      "brightness=-20",
      "contrast=1.25",
      "saturation=0.75",
      "colorize=0.5,blue,keep-alpha",
      "gradient=1,red,left,0.25,0.75"
    ],
    ["region=0,0,600,400", "bg=fff,0.5"],
    ["w=800", "enlarge", "fit=stretch", "format=webp", "q=80"],
    ["w=32", "output=blurhash"]
  ]

  property "re-parsing any permutation of any mutually-compatible base is a stable fixed point" do
    check all base <- StreamData.member_of(@stability_bases),
              permutation <- permutation_of(base) do
      assert {:ok, canonical} = parse(base)
      assert {:ok, ^canonical} = parse(permutation)
      assert {:ok, ^canonical} = parse(permutation)
    end
  end

  describe "canonicalization stability and semantic-default equivalence [API §Canonicalization rules]" do
    property "delivery and storage control order does not change canonical request data" do
      options = [
        "filename=Card_v2.small-1",
        "attachment",
        "cb=deploy_42",
        "expires=1999999999",
        "debug"
      ]

      assert {:ok, canonical} = parse(options)

      check all permutation <- permutation_of(options) do
        assert {:ok, ^canonical} = parse(permutation)
      end
    end

    property "request output option order does not change canonical data" do
      options = [
        "format-q=webp:70,avif:60",
        "meta=copyright",
        "profile=display-p3",
        "hdr=tonemap",
        "autoquality=ssimulacra2,target:78,min:40,max:95,error:2",
        "max-bytes=12000",
        "jpeg-options=progressive,quant-table:3",
        "webp-options=near-lossless,effort:6"
      ]

      assert {:ok, canonical} = parse(options)

      check all permutation <- permutation_of(options) do
        assert {:ok, ^canonical} = parse(permutation)
      end
    end

    test "/w=800 canonicalizes the same as /fit=contain/w=800" do
      assert parse(["w=800"]) == parse(["fit=contain", "w=800"])
    end

    test "/crop=600,400 canonicalizes the same as /crop=600,400/anchor=center" do
      assert parse(["crop=600,400"]) == parse(["crop=600,400", "anchor=center"])
    end

    test "an absent guide with a cover-fit resize consumer also canonicalizes to anchor=center" do
      assert parse(["w=300", "fit=cover"]) == parse(["w=300", "fit=cover", "anchor=center"])
    end

    test "blur=0 canonicalizes the same as blur being entirely absent (Tier-1 identity)" do
      assert parse(["w=800"]) == parse(["w=800", "blur=0"])
      assert parse(["w=800", "blur=0"]) == parse(["w=800", "blur=0.0"])
    end

    test "unit scale spellings canonicalize to their defaults" do
      assert parse(["w=800"]) == parse(["w=800", "zoom=1"])
      assert parse(["w=800"]) == parse(["w=800", "zoom=1.0,1.00"])
      assert parse(["w=800"]) == parse(["w=800", "dpr=1"])
    end

    test "ratio spellings and false enlargement canonicalize to equal crop data" do
      base = ["crop=600,400", "crop-ratio=3:2"]

      assert parse(base) == parse(["crop=600,400", "crop-ratio=1.5"])
      assert parse(base) == parse(["crop=600,400", "crop-ratio=1.500"])
      assert parse(base) == parse(base ++ ["crop-ratio-enlarge=false"])
    end

    test "zero offsets and explicit canvas defaults canonicalize away" do
      crop = ["crop=600,400", "anchor=top-left"]
      canvas = ["w=300", "h=200", "extend"]

      assert parse(crop) == parse(crop ++ ["anchor-offset=0pct,0"])
      assert parse(canvas) == parse(canvas ++ ["extend-at=center"])
      assert parse(canvas) == parse(canvas ++ ["extend-offset=0pct,0"])
    end

    test "integer and decimal offset spellings have identical serialized request identity" do
      for {integer_options, decimal_options} <- [
            {
              ["crop=600,400", "anchor=top-left", "anchor-offset=10,-20pct"],
              ["crop=600,400", "anchor=top-left", "anchor-offset=10.0,-20.0pct"]
            },
            {
              ["w=300", "h=200", "extend", "extend-offset=10,-20pct"],
              ["w=300", "h=200", "extend", "extend-offset=10.0,-20.0pct"]
            }
          ] do
        assert {:ok, integer_request} = parse(integer_options)
        assert {:ok, decimal_request} = parse(decimal_options)
        assert integer_request === decimal_request
        assert :erlang.term_to_binary(integer_request) == :erlang.term_to_binary(decimal_request)
      end
    end

    test "detection class order and numeric weight spellings have identical serialized identity" do
      assert {:ok, first} = parse(["crop=600,400", "detect=face:3,all:1,car"])
      assert {:ok, second} = parse(["detect=car:1.0,face:3.0,all:1.0", "crop=600,400"])
      assert first === second
      assert :erlang.term_to_binary(first) == :erlang.term_to_binary(second)
    end

    test "effect numeric and color spellings have identical serialized identity" do
      integers = [
        "sharpen=2",
        "monochrome=1,red",
        "duotone=1,black,white",
        "contrast=2",
        "saturation=2",
        "colorize=1,red,keep-alpha",
        "gradient=1,red,-90,0,1"
      ]

      decimals = [
        "sharpen=2.0",
        "monochrome=1.0,ff0000",
        "duotone=1.0,000,fff",
        "contrast=2.0",
        "saturation=2.0",
        "colorize=1.0,ff0000,keep-alpha",
        "gradient=1.0,ff0000,270.0,0.0,1.0"
      ]

      assert {:ok, integer_request} = parse(integers)
      assert {:ok, decimal_request} = parse(decimals)
      assert integer_request === decimal_request

      assert :erlang.term_to_binary(integer_request) ==
               :erlang.term_to_binary(decimal_request)

      assert {:ok, negative_turn} = parse(["gradient=1,red,-360"])
      assert {:ok, named_down} = parse(["gradient=1.0,ff0000,down"])
      assert negative_turn === named_down
      assert :erlang.term_to_binary(negative_turn) == :erlang.term_to_binary(named_down)
    end

    test "output option ordering and numeric spellings have identical serialized identity" do
      first = [
        "format-q=webp:70,avif:60",
        "meta=copyright",
        "profile=display-p3",
        "hdr=tonemap",
        "autoquality=ssimulacra2,error:2,target:78,min:40,max:95",
        "jpeg-options=quant-table:3,progressive",
        "webp-options=effort:6,near-lossless"
      ]

      second = [
        "webp-options=near-lossless,effort:6",
        "hdr=tonemap",
        "profile=display-p3",
        "meta=copyright",
        "jpeg-options=progressive,quant-table:3",
        "autoquality=ssimulacra2,max:95,min:40,target:78.0,error:2.0",
        "format-q=avif:60,webp:70"
      ]

      assert {:ok, first_request} = parse(first)
      assert {:ok, second_request} = parse(second)
      assert first_request === second_request
      assert :erlang.term_to_binary(first_request) == :erlang.term_to_binary(second_request)
    end

    test "autoquality positive and negative zero spellings have identical serialized identity" do
      assert {:ok, positive_zero} =
               parse(["autoquality=ssimulacra2,target:0.0,error:0.0"])

      assert {:ok, negative_zero} =
               parse(["autoquality=ssimulacra2,target:-0.0,error:-0.0"])

      assert positive_zero === negative_zero
      assert :erlang.term_to_binary(positive_zero) == :erlang.term_to_binary(negative_zero)
    end
  end

  describe "color spelling equivalence [API §Value micro-syntax, §Colors]" do
    test "3-digit hex, 6-digit hex, and CSS name canonicalize to the same tuple (bg)" do
      assert parse(["bg=fff"]) == parse(["bg=ffffff"])
      assert parse(["bg=fff"]) == parse(["bg=white"])
    end

    test "3-digit hex, 6-digit hex, and CSS name canonicalize to the same tuple (trim)" do
      assert parse(["trim=fff"]) == parse(["trim=ffffff"])
      assert parse(["trim=fff"]) == parse(["trim=white"])
    end

    test "aliased CSS color names canonicalize to an equal %Request{} (bg)" do
      assert {:ok, %_{}} = parse(["bg=aqua"])
      assert parse(["bg=aqua"]) == parse(["bg=cyan"])
    end
  end
end

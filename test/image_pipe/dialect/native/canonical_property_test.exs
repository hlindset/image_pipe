defmodule ImagePipe.Dialect.Native.CanonicalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.Native.Parser

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
    "fit=cover",
    "anchor=smart",
    "blur=2.5",
    "pad=10,20,30,40",
    "bg=fff,0.5",
    "trim=auto"
  ]

  describe "order-insensitivity within a group [native §Canonical form and identity]" do
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
    ["crop=600,400", "anchor=top-left", "trim=fff,10"],
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

  describe "canonicalization stability and semantic-default equivalence [native §Canonicalization rules]" do
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
  end

  describe "color spelling equivalence [native §Value micro-syntax, §Colors]" do
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

defmodule ImagePipe.Dialect.Imgproxy.CanonicalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.Imgproxy.Options
  alias ImagePipe.Dialect.Imgproxy.Presets

  # Pin the two host-config knobs that otherwise fold into the request during
  # defaults resolution, so the properties observe grammar folding alone.
  @defaults [auto_rotate: false, strip_color_profile: false]

  defp parse(segments), do: Options.parse(segments, Presets.empty(), @defaults)

  # A mutually-compatible group of DISTINCT options. Unlike native, imgproxy is
  # last-wins for repeats, so a permutation invariant only holds for a distinct
  # set (property 2 covers repeats separately). Every segment writes a disjoint
  # field except `bg`/`bga`, whose accumulation is itself order-independent
  # (background_color folds the running alpha; background_alpha folds onto the
  # running color) — a genuine invariant a mutation to that accumulation breaks.
  @distinct_group_segments [
    "rt:fill",
    "w:300",
    "h:400",
    "dpr:2",
    "bl:2.5",
    "pd:10",
    "bg:f00",
    "bga:0.5",
    "q:80",
    "f:webp",
    "cb:abc",
    "exp:100"
  ]

  describe "order-insensitivity across a distinct group [imgproxy last-wins]" do
    property "any permutation of a distinct-option group yields an equal request" do
      assert {:ok, canonical} = parse(@distinct_group_segments)

      check all permutation <- permutation_of(@distinct_group_segments) do
        assert {:ok, ^canonical} = parse(permutation)
      end
    end
  end

  describe "last-wins for repeated options [imgproxy §last-wins]" do
    property "a later width assignment overwrites an earlier one" do
      check all first <- integer(0..10_000),
                second <- integer(1..10_000),
                max_runs: 100 do
        assert {:ok, request} = parse(["w:#{first}", "w:#{second}"])
        assert [pipeline] = request.pipelines
        assert pipeline.width == {:pixels, second}
      end
    end

    property "a resize meta-option overwrites atomic width/height fields by position" do
      check all width <- integer(1..10_000),
                height <- integer(1..10_000),
                max_runs: 100 do
        assert {:ok, request} = parse(["w:999", "h:888", "rs:fill:#{width}:#{height}"])
        assert [pipeline] = request.pipelines
        assert pipeline.resizing_type == :fill
        assert pipeline.width == {:pixels, width}
        assert pipeline.height == {:pixels, height}
      end
    end
  end

  describe "alias- and order-equivalent dimension spellings [imgproxy §aliases]" do
    property "atomic order-equivalent and rs-meta alias-equivalent spellings produce equal requests" do
      check all width <- integer(1..2000),
                height <- integer(1..2000) do
        # Order-equivalent atomic spellings.
        assert parse(["w:#{width}", "h:#{height}"]) == parse(["h:#{height}", "w:#{width}"])

        # Alias-equivalent: the `rs` meta-option vs. the atomic `w`/`h`/`rt` triple.
        assert parse(["rs:fit:#{width}:#{height}"]) ==
                 parse(["w:#{width}", "h:#{height}", "rt:fit"])
      end
    end
  end

  defp permutation_of(list) do
    StreamData.uniq_list_of(StreamData.member_of(list),
      length: length(list),
      max_tries: 500
    )
  end
end

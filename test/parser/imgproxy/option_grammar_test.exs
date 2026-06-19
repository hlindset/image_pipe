defmodule ImagePipe.Parser.Imgproxy.OptionGrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Parser.Imgproxy.CropRequest
  alias ImagePipe.Parser.Imgproxy.OptionGrammar
  alias ImagePipe.Plan.Color

  property "zoom aliases parse equivalent zoom_x and zoom_y assignments" do
    check all x_int <- integer(1..2000),
              y_int <- integer(1..2000),
              max_runs: 200 do
      x = decimal_string(x_int)
      y = decimal_string(y_int)

      assert OptionGrammar.parse("zoom:#{x}:#{y}") == OptionGrammar.parse("z:#{x}:#{y}")
    end
  end

  property "fixed-arity option aliases parse equivalently to their long forms" do
    pairs = [
      {"blur", "bl"},
      {"sharpen", "sh"},
      {"pixelate", "pix"},
      {"brightness", "br"},
      {"contrast", "co"},
      {"saturation", "sa"}
    ]

    # Non-empty values only: an empty arg yields {:invalid_option_segment, segment}
    # whose segment string differs by alias (e.g. "blur:" vs "bl:") — an expected
    # artifact, not a divergence. Every non-empty value produces an alias-independent
    # result (a value-tagged error or an {:ok, ...} assignment).
    check all {long, short} <- member_of(pairs),
              value <-
                one_of([
                  map(integer(-200..200), &Integer.to_string/1),
                  map(float(min: -200.0, max: 200.0), &Float.to_string/1),
                  string(:alphanumeric, min_length: 1)
                ]),
              max_runs: 300 do
      assert OptionGrammar.parse("#{long}:#{value}") == OptionGrammar.parse("#{short}:#{value}")
    end
  end

  test "resize full grammar preserves explicit extend_requested assignment" do
    assert OptionGrammar.parse("resize:fill:300:200:1:0") ==
             {:ok,
              {:pipeline,
               [
                 resizing_type: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true,
                 extend: false,
                 extend_requested: true
               ]}}
  end

  test "gravity offsets parse pixels, zero pixels, and scale offsets" do
    assert OptionGrammar.parse("g:soea:12:-0.25") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:anchor, :right, :bottom},
                 gravity_x_offset: {:pixels, 12.0},
                 gravity_y_offset: {:scale, -0.25}
               ]}}

    assert OptionGrammar.parse("gravity:ce:0:0") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:anchor, :center, :center},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "crop focal point and relative offsets parse into crop requests" do
    assert OptionGrammar.parse("c:100:100:fp:0.25:0.75") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: {:fp, 0.25, 0.75}
                 }
               ]}}

    assert OptionGrammar.parse("crop:100:200:nowe:0.25:-0.5") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 200},
                   gravity: {:anchor, :left, :top},
                   x_offset: {:scale, 0.25},
                   y_offset: {:scale, -0.5}
                 }
               ]}}
  end

  test "object gravity parses tail tokens as class names" do
    assert OptionGrammar.parse("g:obj:face") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:obj, ["face"]},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}

    # All tail tokens are class names, never offsets. "5" is a class here.
    assert OptionGrammar.parse("g:obj:face:5:5") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:obj, ["face", "5", "5"]},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}

    # Bare obj carries no class (means "all detected objects" in imgproxy).
    assert OptionGrammar.parse("g:obj") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:obj, []},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "crop object gravity parses tail tokens as class names" do
    assert OptionGrammar.parse("c:100:100:obj:face") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: {:obj, ["face"]}
                 }
               ]}}
  end

  test "crop object gravity with multiple classes parses all tail tokens as class names" do
    assert OptionGrammar.parse("c:100:100:obj:cat:dog") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: {:obj, ["cat", "dog"]}
                 }
               ]}}
  end

  test "extend gravity keeps rejecting object gravity" do
    assert {:error, _} = OptionGrammar.parse("extend:1:obj:face")
    assert {:error, _} = OptionGrammar.parse("ex:1:obj")
  end

  test "extend gravity rejects focal-point gravity (diverges from imgproxy)" do
    # imgproxy's `ExtendGravityTypes` (processing/gravity_type.go) includes
    # `GravityFocusPoint`, so `ex:1:fp:x:y` is accepted upstream. ImagePipe's extend
    # gravity admits only the nine cardinal/corner anchors — `fp`/`sm`/`obj` are
    # crop/cover-only — so it rejects fp on extend. This pins the documented divergence
    # (`docs/imgproxy_support_matrix.md` stage 10/11; #203 T3.2). `fp` is still accepted
    # for `g:`/`c:`, asserted elsewhere.
    assert {:error, _} = OptionGrammar.parse("ex:1:fp:0.3:0.7")
    assert {:error, _} = OptionGrammar.parse("extend:1:fp:0.5:0.5")
  end

  test "malformed padding and background options keep current error shapes" do
    assert OptionGrammar.parse("padding:1:2:3:4:5") ==
             {:error, {:invalid_option_segment, "padding:1:2:3:4:5"}}

    assert OptionGrammar.parse("padding:-1") ==
             {:error, {:invalid_option_segment, "padding:-1"}}

    assert OptionGrammar.parse("padding:one") ==
             {:error, {:invalid_option_segment, "padding:one"}}

    assert OptionGrammar.parse("background:256:0:0") ==
             {:error, {:invalid_background, ["256", "0", "0"]}}

    assert OptionGrammar.parse("background:1:2") ==
             {:error, {:invalid_background, ["1", "2"]}}

    assert OptionGrammar.parse("background:1::2") ==
             {:error, {:invalid_background, ["1", "", "2"]}}

    assert OptionGrammar.parse("background:ffff") ==
             {:error, {:invalid_background, "ffff"}}

    assert OptionGrammar.parse("background_alpha:") ==
             {:error, {:invalid_background_alpha, [""]}}

    assert OptionGrammar.parse("bga:1.1") ==
             {:error, {:invalid_background_alpha, "1.1"}}
  end

  test "background alpha accepts fully transparent zero" do
    assert OptionGrammar.parse("bga:0") ==
             {:ok, {:pipeline, [background_alpha: {:ratio, 0, 1}]}}

    assert OptionGrammar.parse("bga:0.0") ==
             {:ok, {:pipeline, [background_alpha: {:ratio, 0, 10}]}}
  end

  test "basic effect options parse with imgproxy aliases" do
    assert OptionGrammar.parse("blur:2.5") == {:ok, {:pipeline, [blur: 2.5]}}
    assert OptionGrammar.parse("bl:3") == {:ok, {:pipeline, [blur: 3.0]}}
    assert OptionGrammar.parse("bl:0") == {:ok, {:pipeline, [blur: 0.0]}}

    assert OptionGrammar.parse("sharpen:0.7") == {:ok, {:pipeline, [sharpen: 0.7]}}
    assert OptionGrammar.parse("sh:1") == {:ok, {:pipeline, [sharpen: 1.0]}}
    assert OptionGrammar.parse("sh:0") == {:ok, {:pipeline, [sharpen: 0.0]}}

    assert OptionGrammar.parse("pixelate:8") == {:ok, {:pipeline, [pixelate: 8]}}
    assert OptionGrammar.parse("pix:12") == {:ok, {:pipeline, [pixelate: 12]}}
    assert OptionGrammar.parse("pix:0") == {:ok, {:pipeline, [pixelate: 0]}}
  end

  test "brightness accepts imgproxy integer range -255..255" do
    assert OptionGrammar.parse("br:255") == {:ok, {:pipeline, [brightness: 255]}}
    assert OptionGrammar.parse("brightness:-255") == {:ok, {:pipeline, [brightness: -255]}}
    assert OptionGrammar.parse("br:0") == {:ok, {:pipeline, [brightness: 0]}}
    assert OptionGrammar.parse("br:256") == {:error, {:invalid_brightness, "256"}}
    assert OptionGrammar.parse("br:1.5") == {:error, {:invalid_brightness, "1.5"}}
  end

  test "dpr parses positive floats and rejects non-positive values" do
    # imgproxy `parsePositiveNonZeroFloat` (options/parser/parse.go): any float > 0
    # is accepted — including fractional sub-1 DPRs — and <= 0 is rejected. ImagePipe's
    # `:positive_float` matches: 0.5 parses, 0/-1/non-numeric reject (#203 T3.1).
    assert OptionGrammar.parse("dpr:1.5") == {:ok, {:pipeline, [dpr: 1.5]}}
    assert OptionGrammar.parse("dpr:2") == {:ok, {:pipeline, [dpr: 2.0]}}
    assert OptionGrammar.parse("dpr:0.5") == {:ok, {:pipeline, [dpr: 0.5]}}
    assert OptionGrammar.parse("dpr:0") == {:error, {:invalid_positive_float, "0"}}
    assert OptionGrammar.parse("dpr:-1") == {:error, {:invalid_positive_float, "-1"}}
    assert OptionGrammar.parse("dpr:abc") == {:error, {:invalid_positive_float, "abc"}}
  end

  test "blur, sharpen, and pixelate reject invalid values with type-specific tags" do
    assert OptionGrammar.parse("blur:-1") == {:error, {:invalid_non_negative_float, "-1"}}
    assert OptionGrammar.parse("sharpen:abc") == {:error, {:invalid_non_negative_float, "abc"}}
    assert OptionGrammar.parse("pixelate:-1") == {:error, {:invalid_non_negative_integer, "-1"}}
    assert OptionGrammar.parse("pixelate:1.5") == {:error, {:invalid_non_negative_integer, "1.5"}}
  end

  test "tone effect options parse with imgproxy aliases" do
    assert OptionGrammar.parse("monochrome:0.5") ==
             {:ok, {:pipeline, [monochrome: [intensity: {:ratio, 5, 10}]]}}

    assert OptionGrammar.parse("mc:1:ffcc00") ==
             {:ok,
              {:pipeline,
               [
                 monochrome: [
                   intensity: {:ratio, 1, 1},
                   color: color!(255, 204, 0)
                 ]
               ]}}

    assert OptionGrammar.parse("mc:1:") ==
             {:ok, {:pipeline, [monochrome: [intensity: {:ratio, 1, 1}]]}}

    assert OptionGrammar.parse("duotone:0.25") ==
             {:ok, {:pipeline, [duotone: [intensity: {:ratio, 25, 100}]]}}

    assert OptionGrammar.parse("dt:0.5:112233") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 5, 10},
                   shadow: color!(17, 34, 51)
                 ]
               ]}}

    assert OptionGrammar.parse("dt:0.5::ffeecc") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 5, 10},
                   highlight: color!(255, 238, 204)
                 ]
               ]}}

    assert OptionGrammar.parse("dt:1:112233:ffeecc") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 1, 1},
                   shadow: color!(17, 34, 51),
                   highlight: color!(255, 238, 204)
                 ]
               ]}}
  end

  test "invalid tone effect options return parser errors" do
    assert OptionGrammar.parse("mc:") == {:error, {:invalid_option_segment, "mc:"}}
    assert OptionGrammar.parse("mc:1.1") == {:error, {:invalid_intensity, "1.1"}}
    assert OptionGrammar.parse("mc:0.5:zzzzzz") == {:error, {:invalid_monochrome, "zzzzzz"}}

    assert OptionGrammar.parse("mc:0.5:ffffff:000000") ==
             {:error, {:invalid_option_segment, "mc:0.5:ffffff:000000"}}

    assert OptionGrammar.parse("dt:0.5:fffxxx") == {:error, {:invalid_duotone, "fffxxx"}}

    assert OptionGrammar.parse("dt:0.5:ffffff:zzzzzz") ==
             {:error, {:invalid_duotone, ["ffffff", "zzzzzz"]}}
  end

  test "invalid arity pipeline options return invalid option segment errors" do
    for segment <- invalid_pipeline_arity_segments() do
      assert OptionGrammar.parse(segment) == {:error, {:invalid_option_segment, segment}}
    end
  end

  test "dropped options return unknown option errors" do
    for segment <- ~w(
          raw max_bytes mb max_src_resolution msr max_src_file_size msfs
          raw:false max_bytes:100 mb:100
        ) do
      [name | _args] = String.split(segment, ":")

      assert OptionGrammar.parse(segment) == {:error, {:unknown_option, name}}
    end
  end

  defp invalid_pipeline_arity_segments do
    ~w(
      zoom zoom: zoom:1:2:3 z z: z:1:2:3 dpr dpr: dpr:1:2
      min-width min-width:1:2 mw mw:1:2 min_width min_width:1:2
      min-height min-height:1:2 mh mh:1:2 min_height min_height:1:2
      enlarge enlarge:true:false el el:true:false
      extend extend: extend:true:ce:0 extend:true:ce:0:0:extra
      ex ex: ex:true:ce:0 ex:true:ce:0:0:extra
      gravity gravity:ce:0 gravity:ce:0:0:extra
      g g:ce:0 g:ce:0:0:extra
      auto_rotate: auto_rotate:true:false ar: ar:true:false
      rotate rotate: rotate:90:180 rot rot: rot:90:180
      flip:true:false:true fl:true:false:true
      blur blur: bl bl: blur:1:2 bl:1:2
      sharpen sharpen: sh sh: sharpen:1:2 sh:1:2
      pixelate pixelate: pix pix: pixelate:1:2 pix:1:2
      monochrome monochrome: mc mc: monochrome:1:2:3 mc:1:2:3
      duotone duotone: dt dt: dt:1:2:3:4
      extend_aspect_ratio extend_aspect_ratio:1:no:0:0:extra
      extend_ar extend_ar:1:no:0:0:extra
      exar exar:1:no:0:0:extra
      crop crop:100 crop:100:200:ce:0 crop:100:200:ce:0:0:extra
      c c:100 c:100:200:ce:0 c:100:200:ce:0:0:extra
    )
  end

  test "objw gravity parses class/weight pairs (floats)" do
    assert OptionGrammar.parse("g:objw:all:2:face:3") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:objw, [{"all", 2.0}, {"face", 3.0}]},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "objw gravity accepts decimal weights" do
    assert {:ok, {:pipeline, opts}} = OptionGrammar.parse("g:objw:face:2.5")
    assert opts[:gravity] == {:objw, [{"face", 2.5}]}
  end

  test "crop objw gravity parses class/weight pairs" do
    assert {:ok, {:pipeline, [crop: %CropRequest{gravity: gravity}]}} =
             OptionGrammar.parse("c:100:100:objw:all:1:face:3")

    assert gravity == {:objw, [{"all", 1.0}, {"face", 3.0}]}
  end

  test "objw gravity rejects non-positive, odd-arity, empty-class, and bare forms" do
    assert {:error, _} = OptionGrammar.parse("g:objw:face:0")
    assert {:error, _} = OptionGrammar.parse("g:objw:face:-2")
    assert {:error, _} = OptionGrammar.parse("g:objw:all:2:face")
    assert {:error, _} = OptionGrammar.parse("g:objw::3")
    assert {:error, _} = OptionGrammar.parse("g:objw")
  end

  # Bug 1: near-max-float weight must be rejected at parse time, not overflow at centroid math
  test "objw gravity rejects weight above overflow-safe ceiling (1e308)" do
    assert {:error, _} = OptionGrammar.parse("g:objw:cat:1e308")
    assert {:error, _} = OptionGrammar.parse("g:objw:cat:1.0e308")
    assert {:error, _} = OptionGrammar.parse("c:100:100:objw:cat:1e308")
  end

  test "objw gravity accepts large-but-safe weights below the ceiling" do
    assert {:ok, _} = OptionGrammar.parse("g:objw:cat:1000000")
    assert {:ok, _} = OptionGrammar.parse("g:objw:cat:999999.9")
  end

  # Bug 2: parse_float must not raise on very long digit strings (320+ digit tokens)
  test "parse_float-backed options do not raise on 320-digit tokens" do
    huge = String.duplicate("9", 320)

    # objw weight path (parse_positive_float → parse_float)
    assert {:error, _} = OptionGrammar.parse("g:objw:cat:#{huge}")

    # focal-point path (parse_focal_coordinate → parse_float)
    assert {:error, _} = OptionGrammar.parse("g:fp:#{huge}:0.5")

    # zoom path (parse_positive_float → parse_float)
    assert {:error, _} = OptionGrammar.parse("z:#{huge}")

    # dpr path (parse_positive_float → parse_float via @special_specs)
    assert {:error, _} = OptionGrammar.parse("dpr:#{huge}")
  end

  describe "trim" do
    test "parses threshold only (smart background)" do
      assert {:ok, {:pipeline, [trim: trim]}} = OptionGrammar.parse("trim:15")
      assert trim[:threshold] == 15.0
      assert trim[:background] == :auto
      assert trim[:equal_hor] == false
      assert trim[:equal_ver] == false
    end

    test "alias t with color and equal flags" do
      assert {:ok, {:pipeline, [trim: trim]}} = OptionGrammar.parse("t:10:ff00ff:1:1")
      assert trim[:threshold] == 10.0
      assert %ImagePipe.Plan.Color{} = trim[:background]
      assert trim[:equal_hor] == true
      assert trim[:equal_ver] == true
    end

    test "empty threshold disables trim (no assignment)" do
      assert {:ok, {:pipeline, []}} = OptionGrammar.parse("trim:")
    end

    test "rejects more than 4 args" do
      assert {:error, _} = OptionGrammar.parse("trim:10:ff00ff:1:1:0")
    end

    test "rejects more than 4 args even when threshold is empty" do
      # imgproxy runs ensureMaxArgs before the threshold check, so over-arity is
      # rejected regardless of whether trim is enabled.
      assert {:error, _} = OptionGrammar.parse("trim:::::")
    end

    test "rejects a bad threshold" do
      assert {:error, _} = OptionGrammar.parse("trim:nope")
    end

    test "rejects a bad boolean (stricter than imgproxy, like enlarge)" do
      assert {:error, _} = OptionGrammar.parse("trim:10::x")
    end
  end

  defp color!(red, green, blue) do
    assert {:ok, color} = Color.rgb(red, green, blue)
    color
  end

  defp decimal_string(value), do: :erlang.float_to_binary(value / 10, decimals: 1)
end

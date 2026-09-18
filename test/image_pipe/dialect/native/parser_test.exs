defmodule ImagePipe.Native.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Diagnostic
  alias ImagePipe.Native.DiagnosticRenderer
  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Request.Group
  alias ImagePipe.Native.Request.Output
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}

  # `parse/2` consumes Task 4's lexed map directly — never a conn — so
  # tests build that map by hand instead of going through `Path.extract/1`.
  # Span *values* only matter for diagnostic assertions; success-path
  # assertions don't depend on them.
  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source) do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp parse(segments, source \\ "images/cat.jpg", config \\ []) do
    Parser.parse(lexed(segments, source), Config.validate!(config))
  end

  describe "worked examples [native §Examples]" do
    test "srcset workhorse: /w=800/src/images/cat.jpg" do
      assert {:ok, request} = parse(["w=800"])

      assert request == %Request{
               groups: [
                 %Group{
                   resize: %{
                     w: 800,
                     h: :auto,
                     min_w: nil,
                     min_h: nil,
                     fit: :contain,
                     enlarge: false,
                     zoom: {1.0, 1.0}
                   }
                 }
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "fill a box from a focal point, force webp" do
      assert {:ok, request} =
               parse(["fit=cover", "w=300", "h=400", "focus=0.25,0.75", "format=webp"])

      assert request == %Request{
               groups: [
                 %Group{
                   resize: %{
                     w: 300,
                     h: 400,
                     min_w: nil,
                     min_h: nil,
                     fit: :cover,
                     enlarge: false,
                     zoom: {1.0, 1.0}
                   },
                   guide: {:focus, 0.25, 0.75}
                 }
               ],
               output: %Output{terminal: :image, format: :webp, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "explicit smart crop, then resize down" do
      assert {:ok, request} = parse(["crop=600,400", "anchor=smart", "w=300"])

      assert request == %Request{
               groups: [
                 %Group{
                   crop: {{:px, 600}, {:px, 400}},
                   guide: {:anchor_smart},
                   resize: %{
                     w: 300,
                     h: :auto,
                     min_w: nil,
                     min_h: nil,
                     fit: :contain,
                     enlarge: false,
                     zoom: {1.0, 1.0}
                   }
                 }
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "cheap trim: resize first, trim the small image" do
      assert {:ok, request} = parse(["w=500", "then", "trim=fff"])

      assert request == %Request{
               groups: [
                 %Group{
                   resize: %{
                     w: 500,
                     h: :auto,
                     min_w: nil,
                     min_h: nil,
                     fit: :contain,
                     enlarge: false,
                     zoom: {1.0, 1.0}
                   }
                 },
                 %Group{trim: {{255, 255, 255}, 10}}
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "trim=color defaults its tolerance to 10, canonically equal to explicit ,10" do
      assert {:ok, defaulted} = parse(["trim=fff"])
      assert {:ok, explicit} = parse(["trim=fff,10"])

      assert [%Group{trim: {{255, 255, 255}, 10}}] = defaulted.groups
      # Same canonical request as the explicit spelling -> same cache key/ETag.
      assert defaulted == explicit
      # A different tolerance must NOT collapse onto the default.
      assert {:ok, other} = parse(["trim=fff,5"])
      refute defaulted == other
    end

    test "relative crop with explicit units" do
      assert {:ok, request} = parse(["crop=80pct,60pct"])

      assert request == %Request{
               groups: [
                 %Group{
                   crop: {{:pct, 80}, {:pct, 60}},
                   guide: {:anchor, :center}
                 }
               ],
               output: %Output{terminal: :image, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end

    test "blurhash placeholder terminal (no format/quality)" do
      assert {:ok, request} = parse(["w=32", "output=blurhash"])

      assert request == %Request{
               groups: [
                 %Group{
                   resize: %{
                     w: 32,
                     h: :auto,
                     min_w: nil,
                     min_h: nil,
                     fit: :contain,
                     enlarge: false,
                     zoom: {1.0, 1.0}
                   }
                 }
               ],
               output: %Output{terminal: :blurhash, format: nil, quality: nil},
               source: "images/cat.jpg",
               expires: nil
             }
    end
  end

  describe "happy path per option" do
    test "dpr is group-scoped and does not require resize intent" do
      assert {:ok, %Request{groups: [%Group{dpr: 2.0, resize: nil}]}} = parse(["dpr=2"])
    end

    test "w alone builds a resize with h defaulted to auto" do
      assert {:ok, %Request{groups: [%Group{resize: %{w: 800, h: :auto}}]}} = parse(["w=800"])
    end

    test "h alone builds a resize with w defaulted to auto" do
      assert {:ok, %Request{groups: [%Group{resize: %{w: :auto, h: 600}}]}} = parse(["h=600"])
    end

    test "fit with a resize intent" do
      assert {:ok, %Request{groups: [%Group{resize: %{fit: :stretch}}]}} =
               parse(["w=800", "fit=stretch"])
    end

    test "enlarge with a resize intent" do
      assert {:ok, %Request{groups: [%Group{resize: %{enlarge: true}}]}} =
               parse(["w=800", "enlarge"])
    end

    test "minimum dimensions create resize intent without w or h" do
      assert {:ok,
              %Request{
                groups: [
                  %Group{resize: %{w: :auto, h: :auto, min_w: 320, min_h: 240}}
                ]
              }} = parse(["min-w=320", "min-h=240"])
    end

    test "zoom scalar and pair values are canonical resize data" do
      assert {:ok, %Request{groups: [%Group{resize: %{zoom: {2.0, 2.0}}}]}} =
               parse(["w=800", "zoom=2"])

      assert {:ok, %Request{groups: [%Group{resize: %{zoom: {1.25, 0.75}}}]}} =
               parse(["min-w=320", "zoom=1.25,0.75"])
    end

    test "box and ratio canvas carry placement while resize keeps raw dimensions" do
      assert {:ok,
              %Request{
                groups: [
                  %Group{
                    resize: %{w: 300, h: 200},
                    canvas: %{
                      mode: :box,
                      at: :center,
                      offset: {{:px, 0}, {:px, 0}}
                    }
                  }
                ]
              }} = parse(["w=300", "h=200", "extend"])

      assert {:ok,
              %Request{
                groups: [
                  %Group{
                    resize: %{w: 300, h: 200},
                    canvas: %{
                      mode: :ratio,
                      at: :bottom_right,
                      offset: {{:px, 10.0}, {:pct, -20.0}}
                    }
                  }
                ]
              }} =
               parse([
                 "w=300",
                 "h=200",
                 "extend-ratio",
                 "extend-at=bottom-right",
                 "extend-offset=10,-20pct"
               ])
    end

    test "unit zoom without resize intent canonicalizes away" do
      assert parse(["zoom=1"]) == parse([])
      assert parse(["zoom=1,1"]) == parse([])
    end

    test "crop alone defaults its guide to anchor=center" do
      assert {:ok,
              %Request{
                groups: [%Group{crop: {{:px, 600}, {:px, 400}}, guide: {:anchor, :center}}]
              }} =
               parse(["crop=600,400"])
    end

    test "crop ratio and enlargement are canonical crop data" do
      assert {:ok,
              %Request{
                groups: [
                  %Group{
                    crop_ratio: {:ratio, 3, 2},
                    crop_ratio_enlarge: true
                  }
                ]
              }} = parse(["crop=600,400", "crop-ratio=3:2", "crop-ratio-enlarge"])
    end

    test "region needs no guide" do
      assert {:ok,
              %Request{
                groups: [%Group{region: {{:px, 0}, {:px, 0}, {:px, 600}, {:px, 400}}, guide: nil}]
              }} =
               parse(["region=0,0,600,400"])
    end

    test "anchor with a crop consumer" do
      assert {:ok, %Request{groups: [%Group{guide: {:anchor, :top_left}}]}} =
               parse(["crop=600,400", "anchor=top-left"])
    end

    test "anchor offset is separate canonical guide placement data" do
      assert {:ok,
              %Request{
                groups: [
                  %Group{
                    guide: {:anchor, :top_left},
                    anchor_offset: {{:px, -10.0}, {:pct, 20.0}}
                  }
                ]
              }} = parse(["crop=600,400", "anchor=top-left", "anchor-offset=-10,20pct"])
    end

    test "focus with a cover-fit resize consumer" do
      assert {:ok, %Request{groups: [%Group{guide: {:focus, 0.1, 0.2}}]}} =
               parse(["w=300", "fit=cover", "focus=0.1,0.2"])
    end

    test "detection guides carry canonical class selection and sparse weights" do
      assert {:ok, %Request{groups: [%Group{guide: {:detect, {:all, %{}}}}]}} =
               parse(["crop=600,400", "detect=all"])

      assert {:ok,
              %Request{
                groups: [
                  %Group{guide: {:detect, {["car", "face"], %{"face" => 3.0}}}}
                ]
              }} = parse(["crop=600,400", "detect=face:3,car"])

      assert {:ok, %Request{groups: [%Group{guide: {:detect, {:all, %{"face" => 3.0}}}}]}} =
               parse(["w=300", "fit=cover", "detect=all:1,face:3"])
    end

    test "smart-face is explicit face-assisted attention" do
      assert {:ok, %Request{groups: [%Group{guide: {:smart, :face_assist}}]}} =
               parse(["crop=600,400", "anchor=smart-face"])
    end

    test "blur with a non-zero sigma" do
      assert {:ok, %Request{groups: [%Group{blur: 3.0}]}} = parse(["blur=3"])
    end

    test "retained effects assemble complete canonical group data" do
      assert {:ok,
              %Request{
                groups: [
                  %Group{
                    sharpen: 1.5,
                    pixelate: 8,
                    monochrome: %{intensity: 0.5, color: {179, 179, 179}},
                    duotone: %{
                      intensity: 1.0,
                      shadow: {17, 34, 51},
                      highlight: {255, 238, 204}
                    },
                    brightness: -20,
                    contrast: 1.25,
                    saturation: 0.75,
                    colorize: %{opacity: 0.5, color: {255, 0, 0}, keep_alpha: true},
                    gradient: %{
                      opacity: 1.0,
                      color: {0, 0, 255},
                      angle: 90.0,
                      start: 0.25,
                      stop: 0.75
                    }
                  }
                ]
              }} =
               parse([
                 "sharpen=1.5",
                 "pixelate=8",
                 "monochrome=0.5",
                 "duotone=1,112233,ffeecc",
                 "brightness=-20",
                 "contrast=1.25",
                 "saturation=0.75",
                 "colorize=0.5,red,keep-alpha",
                 "gradient=1,blue,left,0.25,0.75"
               ])
    end

    test "effect identity values canonicalize away" do
      identities = [
        "sharpen=0",
        "pixelate=1",
        "monochrome=0,red",
        "duotone=0,black,white",
        "brightness=0",
        "contrast=1",
        "saturation=1.0",
        "colorize=0,red,keep-alpha",
        "gradient=0,blue,left,0.25,0.75"
      ]

      assert parse(identities) === parse([])
    end

    test "trim=auto" do
      assert {:ok, %Request{groups: [%Group{trim: :auto}]}} = parse(["trim=auto"])
    end

    test "trim symmetry is canonical group data" do
      assert {:ok, %Request{groups: [%Group{trim_symmetry: :both}]}} =
               parse(["trim=auto", "trim-symmetry=hv"])
    end

    test "false crop ratio enlargement canonicalizes away" do
      assert parse(["crop-ratio-enlarge=false"]) == parse([])

      assert parse(["crop=600,400", "crop-ratio=3:2", "crop-ratio-enlarge=false"]) ==
               parse(["crop=600,400", "crop-ratio=3:2"])
    end

    test "disabled canvas flags canonicalize away" do
      assert parse(["extend=false"]) == parse([])
      assert parse(["extend-ratio=false"]) == parse([])
      assert parse(["extend=false", "extend-ratio=false"]) == parse([])
    end

    test "pad shorthand" do
      assert {:ok, %Request{groups: [%Group{pad: {10, 20, 10, 20}}]}} = parse(["pad=10,20"])
    end

    test "bg with alpha" do
      assert {:ok, %Request{groups: [%Group{bg: {255, 255, 255, 0.5}}]}} =
               parse(["bg=fff,0.5"])
    end

    test "output=image is the identity default, stated explicitly" do
      assert {:ok, %Request{output: %Output{terminal: :image}}} = parse(["output=image"])
    end

    test "format alone (negotiated output)" do
      assert {:ok, %Request{output: %Output{format: :avif}}} = parse(["format=avif"])
    end

    test "q alone" do
      assert {:ok, %Request{output: %Output{quality: 80}}} = parse(["q=80"])
    end

    test "output policy stays sparse and typed" do
      options = [
        "format-q=webp:70,avif:60,jxl:80",
        "autoquality=ssimulacra2,error:2,target:78,min:40,max:95",
        "max-bytes=12000",
        "jpeg-options=progressive,quant-table:3",
        "png-options=palette:false,filter:paeth",
        "webp-options=near-lossless,effort:6",
        "avif-options=subsample:on,effort:9",
        "jxl-options=effort:4"
      ]

      assert {:ok,
              %Request{
                output: %Output{
                  format_qualities: %{
                    webp: {:quality, 70},
                    avif: {:quality, 60},
                    jpeg_xl: {:quality, 80}
                  },
                  autoquality:
                    {:ssimulacra2,
                     [target: 78.0, min_quality: 40, max_quality: 95, allowed_error: 2.0]},
                  max_bytes: 12_000,
                  encoder_options: %{
                    jpeg: %JpegOptions{interlace: true, quant_table: 3},
                    png: %PngOptions{palette: false, filter: :paeth},
                    webp: %WebpOptions{near_lossless: true, effort: 6},
                    avif: %AvifOptions{subsample_mode: :on, effort: 9},
                    jpeg_xl: %JxlOptions{effort: 4}
                  }
                }
              }} = parse(options)
    end

    test "q retains precedence intent beside format qualities" do
      assert {:ok,
              %Request{
                output: %Output{quality: 80, format_qualities: %{webp: {:quality, 70}}}
              }} =
               parse(["q=80", "format-q=webp:70"])
    end

    test "q may explicitly disable inherited autoquality" do
      assert {:ok, %Request{output: %Output{quality: 80, autoquality: :none}}} =
               parse(["q=80", "autoquality=none"])
    end

    test "expires as a gate field" do
      assert {:ok, %Request{expires: 1_999_999_999}} = parse(["expires=1999999999"])
    end

    test "an overridden-away preset is grammar-validated but never reaches the canonical request" do
      config = [presets: %{"card" => "w=999"}]

      assert {:ok, with_preset} = parse(["preset=card", "w=800"], "images/cat.jpg", config)
      assert {:ok, without_preset} = parse(["w=800"])
      assert with_preset == without_preset
    end

    test "an invalid preset name is still a 400" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["preset=bad!name", "w=800"])
      assert Enum.any?(diagnostics, &(&1.reason == :invalid_preset_name))
    end
  end

  describe "400s: unknown key / invalid value" do
    test "unknown key" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["bogus=10"])
      assert Enum.any?(diagnostics, &(&1.reason == :unknown_option))
    end

    test "invalid value for a known key" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=notanumber"])
      assert Enum.any?(diagnostics, &(&1.reason == :invalid_dimension))
    end

    test "invalid dpr, zoom, and minimum dimensions report their option errors" do
      for {segment, reason} <- [
            {"dpr=0", :invalid_dpr},
            {"zoom=0", :invalid_zoom},
            {"min-w=auto", :invalid_min_dimension},
            {"min-h=0", :invalid_min_dimension}
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse([segment])
        assert Enum.any?(diagnostics, &(&1.reason == reason))
      end
    end

    test "malformed crop ratio and trim symmetry fail at the request boundary" do
      huge_ratio = String.duplicate("9", 400)

      for {segment, reason} <- [
            {"crop-ratio=1:0", :invalid_crop_ratio},
            {"crop-ratio=1e2", :invalid_crop_ratio},
            {"crop-ratio=#{huge_ratio}:1", :invalid_crop_ratio},
            {"crop-ratio=1:#{huge_ratio}", :invalid_crop_ratio},
            {"trim-symmetry=vh", :invalid_trim_symmetry}
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse([segment])
        assert Enum.any?(diagnostics, &(&1.reason == reason))
      end
    end

    test "malformed placement options fail at the request boundary" do
      huge = String.duplicate("9", 400)

      for {segment, reason} <- [
            {"anchor-offset=10", :invalid_offset},
            {"anchor-offset=#{huge},0", :invalid_offset},
            {"extend-offset=10,20,30", :invalid_offset},
            {"extend-at=smart", :invalid_anchor},
            {"extend-at=smart-face", :invalid_anchor}
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse([segment])
        assert Enum.any?(diagnostics, &(&1.reason == reason))
      end
    end

    test "malformed detection values fail at the request boundary" do
      for value <- ["face,face:2", "face:0", "face:1000000.1", "traffic light", "face:"] do
        assert {:error, {:invalid_request, diagnostics}} =
                 parse(["crop=600,400", "detect=#{value}"])

        assert Enum.any?(diagnostics, &(&1.reason == :invalid_detect))
      end
    end

    test "malformed retained effects fail at the request boundary" do
      for {segment, reason} <- [
            {"sharpen=-1", :invalid_sharpen},
            {"pixelate=0", :invalid_pixelate},
            {"monochrome=0.5,red,blue", :invalid_monochrome},
            {"duotone=0.5,black", :invalid_duotone},
            {"brightness=1.5", :invalid_brightness},
            {"contrast=0", :invalid_contrast},
            {"saturation=-1", :invalid_saturation},
            {"colorize=0.5", :invalid_colorize},
            {"gradient=1,red,sideways", :invalid_gradient}
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse([segment])
        assert Enum.any?(diagnostics, &(&1.reason == reason))
      end
    end

    test "pixel offsets reject a group DPR combination that overflows float geometry" do
      large = "1" <> String.duplicate("0", 200)

      for options <- [
            ["crop=10,10", "anchor=left", "anchor-offset=#{large},0", "dpr=#{large}"],
            ["w=10", "h=10", "extend", "extend-offset=#{large},0", "dpr=#{large}"]
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse(options)
        assert Enum.any?(diagnostics, &(&1.reason == :invalid_offset))
      end

      assert {:ok, %Request{groups: [%Group{anchor_offset: {{:pct, _large}, {:px, 0}}}]}} =
               parse([
                 "crop=10,10",
                 "anchor=left",
                 "anchor-offset=#{large}pct,0",
                 "dpr=#{large}"
               ])
    end

    test "key=true is a specific error, not a generic invalid value" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "enlarge=true"])
      assert Enum.any?(diagnostics, &(&1.reason == :true_spelled_bare))
    end

    test "errors accumulate across independent violations" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["bogus=10", "w=notanumber"])
      reasons = Enum.map(diagnostics, & &1.reason)
      assert :unknown_option in reasons
      assert :invalid_dimension in reasons
    end
  end

  describe "400s: duplicates [native §Scoping and duplicates]" do
    test "group-scoped key twice in a group" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "w=900"])
      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "duplicate diagnostic carries every participating span" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "w=900"])

      assert %{reason: :duplicate_option, spans: spans} =
               Enum.find(diagnostics, &(&1.reason == :duplicate_option))

      assert length(spans) == 2
    end

    test "request-scoped key twice anywhere in the URL" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["format=webp", "w=800", "then", "format=avif"])

      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "the same key in different groups is not a duplicate" do
      assert {:ok, _request} = parse(["w=800", "then", "w=400"])
    end
  end

  describe "400s: Tier-3 mutually exclusive pairs" do
    test "focus and anchor in the same group" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "anchor=center", "focus=0.5,0.5"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end

    test "detect conflicts with anchor and focus" do
      for alternative <- ["anchor=center", "focus=0.5,0.5"] do
        assert {:error, {:invalid_request, diagnostics}} =
                 parse(["crop=600,400", "detect=face", alternative])

        assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
      end
    end

    test "crop and region in the same group" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "region=0,0,600,400"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end

    test "enabled box and ratio canvas are mutually exclusive" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=300", "h=200", "extend", "extend-ratio"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))

      assert {:ok, %Request{groups: [%Group{canvas: %{mode: :box}}]}} =
               parse(["w=300", "h=200", "extend", "extend-ratio=false"])
    end
  end

  describe "400s: Tier-2 inertness (locked probe decisions)" do
    test "fit without a resize intent is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["fit=cover"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "enlarge without a resize intent is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["enlarge"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "non-unit zoom without a resize intent is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["zoom=1,2"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "minimum dimensions satisfy fit and enlarge resize intent" do
      assert {:ok, %Request{groups: [%Group{resize: %{fit: :cover, enlarge: true}}]}} =
               parse(["min-w=320", "fit=cover", "enlarge"])
    end

    test "crop ratio without crop is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["crop-ratio=3:2"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "true crop ratio enlargement without crop ratio is inert" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "crop-ratio-enlarge"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "trim symmetry without trim is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["trim-symmetry=h"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "enabled canvas requires concrete w and h" do
      for options <- [
            ["extend"],
            ["w=300", "extend"],
            ["w=300", "h=auto", "extend"],
            ["h=200", "extend-ratio"]
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse(options)
        assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
      end
    end

    test "canvas placement requires an enabled canvas" do
      for options <- [
            ["extend-at=top-left"],
            ["extend-offset=10,20"],
            ["extend=false", "extend-at=top-left"],
            ["extend-ratio=false", "extend-offset=10,20"]
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse(options)
        assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
      end
    end

    test "anchor offset requires an explicit non-smart anchor" do
      for options <- [
            ["crop=600,400", "anchor-offset=10,20"],
            ["crop=600,400", "anchor=smart", "anchor-offset=10,20"],
            ["crop=600,400", "anchor=smart-face", "anchor-offset=10,20"]
          ] do
        assert {:error, {:invalid_request, diagnostics}} = parse(options)
        assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
      end
    end

    test "a lone auto dimension is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=auto"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "a doubled auto dimension is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=auto", "h=auto"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "anchor without a consumer is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["anchor=center"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "focus without a consumer is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["focus=0.5,0.5"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "detect without a consumer is inert" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["detect=face"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "anchor with a contain-fit resize is still inert (not a guide consumer)" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "anchor=center"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "fit=auto counts as a valid guide consumer at parse time" do
      assert {:ok, %Request{groups: [%Group{guide: {:anchor, :center}}]}} =
               parse(["w=800", "fit=auto"])
    end

    test "format with output=blurhash is inert" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=32", "output=blurhash", "format=webp"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "q with output=blurhash is inert" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=32", "output=blurhash", "q=80"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "advanced output options with output=blurhash are inert" do
      for option <- [
            "format-q=webp:70",
            "autoquality=none",
            "max-bytes=10000",
            "jpeg-options=progressive",
            "png-options=palette",
            "webp-options=lossless",
            "avif-options=effort:6",
            "jxl-options=effort:4"
          ] do
        assert {:error, {:invalid_request, diagnostics}} =
                 parse(["w=32", "output=blurhash", option])

        assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
      end
    end

    test "an explicit format rejects another codec's URL options" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["format=webp", "jpeg-options=progressive"])

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "negotiated output accepts options for multiple codecs" do
      assert {:ok, %Request{output: %Output{encoder_options: options}}} =
               parse(["jpeg-options=progressive", "webp-options=lossless"])

      assert Map.keys(options) |> Enum.sort() == [:jpeg, :webp]
    end

    test "PNG rejects enabled URL quality searches" do
      for option <- ["autoquality=size,target:10000", "max-bytes=10000"] do
        assert {:error, {:invalid_request, diagnostics}} = parse(["format=png", option])
        assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
      end

      assert {:ok, %Request{output: %Output{format: :png, autoquality: :none}}} =
               parse(["format=png", "autoquality=none"])
    end

    test "q conflicts with enabled URL autoquality" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["q=80", "autoquality=ssimulacra2,target:78"])

      assert Enum.any?(diagnostics, &(&1.reason == :mutually_exclusive_options))
    end
  end

  describe "400s: Tier-2 inertness derivative-error suppression [native §Error diagnostics]" do
    test "a present-but-invalid w suppresses enlarge's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=invalid", "enlarge"])
      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid minimum dimension suppresses zoom inertness" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["min-w=invalid", "zoom=2"])
      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_min_dimension in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid w suppresses fit's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=invalid", "fit=cover"])
      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid crop suppresses anchor's own inertness complaint" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=abc,def", "anchor=top-left"])

      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_element in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid crop suppresses crop ratio inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=invalid", "crop-ratio=3:2"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :invalid_arity in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid crop ratio suppresses enlargement inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "crop-ratio=invalid", "crop-ratio-enlarge"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :invalid_crop_ratio in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid trim suppresses symmetry inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["trim=invalid", "trim-symmetry=v"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :invalid_element in reasons
      refute :inert_option in reasons
    end

    test "invalid canvas dimensions suppress enabled-canvas inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=invalid", "h=200", "extend"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "an invalid canvas flag suppresses placement inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=300", "h=200", "extend=true", "extend-at=top-left"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :true_spelled_bare in reasons
      refute :inert_option in reasons
    end

    test "an invalid anchor suppresses anchor offset inertness" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["crop=600,400", "anchor=invalid", "anchor-offset=10,20"])

      reasons = Enum.map(diagnostics, & &1.reason)
      assert :invalid_anchor in reasons
      refute :inert_option in reasons
    end

    test "a present-but-invalid w suppresses focus's own inertness complaint (guide consumer via cover-fit)" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["fit=cover", "w=invalid", "focus=0.5,0.5"])

      reasons = Enum.map(diagnostics, & &1.reason)

      assert :invalid_dimension in reasons
      refute :inert_option in reasons
    end

    test "a genuinely absent prerequisite still triggers the dependent's inertness (no w/h at all)" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["enlarge"])
      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end
  end

  describe "400s: empty pipeline groups" do
    test "leading then" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["then", "w=800"])
      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "trailing then" do
      assert {:error, {:invalid_request, diagnostics}} = parse(["w=800", "then"])
      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "doubled then" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["w=800", "then", "then", "h=400"])

      assert Enum.any?(diagnostics, &(&1.reason == :empty_pipeline_group))
    end

    test "no then at all is a single, legitimately-empty group and is not an error" do
      assert {:ok, %Request{groups: [%Group{}]}} = parse([])
    end
  end

  describe "presets [native §Presets, trimmed to probe]" do
    test "a named preset contributes options the URL never states" do
      config = [presets: %{"card" => "w=300/fit=cover"}]

      assert {:ok, request} = parse(["preset=card"], "images/cat.jpg", config)

      assert %Request{
               groups: [
                 %Group{resize: %{w: 300, h: :auto, fit: :cover, enlarge: false}}
               ]
             } = request
    end

    test "the default preset applies with no preset= segment in the URL at all" do
      config = [presets: %{"default" => "blur=2.5"}]

      assert {:ok, %Request{groups: [%Group{blur: 2.5}]}} =
               parse(["w=800"], "images/cat.jpg", config)
    end

    test "precedence chain: default < named presets in URL order < explicit URL options" do
      config = [
        presets: %{
          "default" => "blur=1",
          "a" => "blur=2/trim=auto",
          "b" => "blur=3"
        }
      ]

      # explicit w=800 is untouched by any level; blur is set by "default",
      # displaced by "a", then displaced again by "b" (last-listed named
      # preset wins); trim survives from "a" since nothing displaces it.
      assert {:ok, request} = parse(["preset=a,b", "w=800"], "images/cat.jpg", config)

      assert %Request{
               groups: [
                 %Group{
                   resize: %{w: 800, h: :auto, fit: :contain, enlarge: false},
                   blur: 3.0,
                   trim: :auto
                 }
               ]
             } = request
    end

    test "an explicit URL option displaces every preset level for that key" do
      config = [presets: %{"default" => "w=100", "card" => "w=300"}]

      assert {:ok, request} = parse(["preset=card", "w=800"], "images/cat.jpg", config)
      assert %Request{groups: [%Group{resize: %{w: 800}}]} = request
    end

    test "an unknown preset name is a 400" do
      assert {:error, {:invalid_request, diagnostics}} =
               parse(["preset=nope", "w=800"], "images/cat.jpg", presets: %{})

      assert Enum.any?(diagnostics, &(&1.reason == :unknown_preset))
    end

    test "a preset-contributed key can still trigger Tier-2 inertness on the merged group" do
      # `fit=cover` alone (no resize intent from either the preset or the
      # URL) is inert — cross-option validation runs over the *merged*
      # group, not just the URL's own explicit segments.
      config = [presets: %{"cover" => "fit=cover"}]

      assert {:error, {:invalid_request, diagnostics}} =
               parse(["preset=cover"], "images/cat.jpg", config)

      assert Enum.any?(diagnostics, &(&1.reason == :inert_option))
    end

    test "a preset combined with an explicit dimension satisfies its own inertness prerequisite" do
      config = [presets: %{"cover" => "fit=cover"}]

      assert {:ok, %Request{groups: [%Group{resize: %{fit: :cover}}]}} =
               parse(["preset=cover", "w=800"], "images/cat.jpg", config)
    end

    test "a default-preset-only inertness diagnostic anchors to the whole raw path, not {0, 0}" do
      # No `preset=` segment at all — the `default` preset applies purely
      # from config, so there is no real segment for the resulting
      # cross-option diagnostic to anchor to. It must fall back to the
      # whole raw path, not a zero-length {0, 0} span.
      config = [presets: %{"default" => "fit=cover"}]
      raw_path = "/src/images/cat.jpg"
      lexed = %{segments: [], source: {:src, "images/cat.jpg", {5, 14}}}

      assert {:error, {:invalid_request, diagnostics}} =
               Parser.parse(lexed, Config.validate!(config))

      assert [%Diagnostic{reason: :inert_option, spans: [{0, 19}]}] = diagnostics
      assert byte_size(raw_path) == 19

      rendered =
        raw_path
        |> DiagnosticRenderer.render(diagnostics)
        |> IO.iodata_to_binary()

      assert rendered =~ String.duplicate("^", 19)
    end

    test "a host preset literally named `default` combined with an explicit preset=default is idempotent" do
      config = [presets: %{"default" => "blur=2"}]

      assert {:ok, applied_once} = parse(["w=800"], "images/cat.jpg", config)

      assert {:ok, applied_explicitly} =
               parse(["preset=default", "w=800"], "images/cat.jpg", config)

      assert applied_once == applied_explicitly
    end

    property "an overridden-away preset never changes the canonical %Request{}" do
      check all preset_w <- StreamData.integer(1..4000),
                url_w <- StreamData.integer(1..4000) do
        config = [presets: %{"card" => "w=#{preset_w}"}]

        assert parse(["preset=card", "w=#{url_w}"], "images/cat.jpg", config) ==
                 parse(["w=#{url_w}"])
      end
    end
  end
end

defmodule ImagePipe.BuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan

  # Semantic checks need to know the mount's presets; this mount has none.
  @known IP.URL.config(validate_against: [])

  test "builds reusable, source-independent plans with explicit groups" do
    plan =
      IP.URL.new(orient: :none)
      |> IP.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart, dpr: 2)
      |> IP.URL.group(trim: :auto, padding: 20, background: "#ffffff")
      |> IP.URL.output(format: :webp, quality: 82)

    assert :ok = IP.URL.validate(plan)
    assert {:ok, first} = Plan.to_spec(plan.plan)
    assert first.orient == :none
    assert first.output.format == :webp
    assert first.output.quality == 82
    assert [resize, trim] = first.groups
    assert resize.resize.w == 400
    assert resize.resize.h == 300
    assert resize.guide == {:anchor_smart}
    assert trim.resize == nil
    assert trim.dpr == 1.0
    assert trim.pad == {20, 20, 20, 20}
    assert trim.bg == {255, 255, 255, 1.0}
  end

  test "output overrides leave the original plan reusable and defaults sparse" do
    base = IP.URL.new() |> IP.URL.output(format: :webp, quality: 80)
    changed = IP.URL.output(base, quality: 60)
    assert {:ok, original} = Plan.to_spec(base.plan)
    assert {:ok, updated} = Plan.to_spec(changed.plan)
    assert original.output.quality == 80
    assert updated.output.quality == 60
    assert updated.output.format == :webp
    assert updated.output.metadata == nil
    assert updated.output.autoquality == nil
  end

  test "rejects malformed public values immediately" do
    for options <- [
          [resize: [width: 0]],
          [resize: [width: "400"]],
          [blur: -1],
          [progressive_blur: [sigma: -1]],
          [progressive_blur: [sigma: 0, start: 2]],
          [progressive_blur: [direction: 90]],
          [dpr: 0],
          [crop: {0, 20}],
          [region: {-1, 0, 20, 20}],
          [region: {0, {:pct, -5}, 20, 20}],
          [gray: "true"],
          [mystery: 1],
          [blur: 1, blur: 2],
          [blur: :unset, blur: 2],
          [resize: [width: 2, width: 3]],
          [resize: [fit: :unset, fit: :cover]]
        ] do
      assert_raise ArgumentError, fn -> IP.URL.group(IP.URL.new(), options) end
    end

    assert_raise ArgumentError, fn -> IP.URL.output(IP.URL.new(), quality: 101) end
    assert_raise ArgumentError, fn -> IP.URL.output(IP.URL.new(), dpi: 0) end
    assert_raise ArgumentError, fn -> IP.URL.output(IP.URL.new(), dpi: 65_536) end
    assert_raise ArgumentError, fn -> IP.URL.new(orient: :sideways) end
    assert_raise ArgumentError, fn -> IP.URL.new(page: -1) end
  end

  test "effect directions take the URL's names or degrees" do
    for {name, degrees} <- [down: 0, left: 90, up: 180, right: 270] do
      named =
        IP.URL.new()
        |> IP.URL.group(
          gradient: [opacity: 1, color: "red", direction: name],
          progressive_blur: [sigma: 2, direction: name]
        )

      numeric =
        IP.URL.new()
        |> IP.URL.group(
          gradient: [opacity: 1, color: "red", direction: degrees],
          progressive_blur: [sigma: 2, direction: degrees]
        )

      assert IP.URL.url!(named, "a.jpg") == IP.URL.url!(numeric, "a.jpg")
    end

    assert_raise ArgumentError, fn ->
      IP.URL.group(IP.URL.new(), gradient: [opacity: 1, color: "red", direction: :sideways])
    end
  end

  test "an invalid value's error lists only the values the option accepts" do
    for {build, expected} <- [
          {fn -> IP.URL.group(IP.URL.new(), resize: [width: 300, fit: :fill]) end,
           "expected one of [:contain, :cover, :stretch, :auto], got: :fill"},
          {fn -> IP.URL.group(IP.URL.new(), flip: :diag) end,
           "expected one of [:horizontal, :vertical, :both], got: :diag"},
          {fn -> IP.URL.output(IP.URL.new(), format: :bmp) end,
           "expected one of [:jpeg, :png, :webp, :avif], got: :bmp"},
          {fn -> IP.URL.new(orient: :sideways) end,
           "expected one of [:auto, :none], got: :sideways"}
        ] do
      message = Exception.message(assert_raise(ArgumentError, build))
      assert message =~ expected
      refute message =~ ":unset"
    end
  end

  test "rejects empty groups, malformed nested values, and duplicate nested settings" do
    for options <- [
          [],
          [resize: []],
          [detect: []],
          [detect: ["face", "face"]],
          [detect: [{"face", 0}]],
          [background: {"red", 2}],
          [gradient: [opacity: 0.5, color: "red", start: -1]],
          [monochrome: [intensity: 0.5, intensity: 0.8]],
          [dpr: Integer.pow(10, 400)],
          [crop_ratio: {1, Integer.pow(10, 400)}]
        ] do
      assert_raise ArgumentError, fn -> IP.URL.group(IP.URL.new(), options) end
    end

    for options <- [
          [jpeg_options: [quant_table: 9]],
          [png_options: [bitdepth: 3]],
          [webp_options: [effort: 7]],
          [format_qualities: [webp: 70, webp: 80]],
          [autoquality: {:size, target: 0}],
          [autoquality: {:size, target: 1.5}],
          [autoquality: {:ssimulacra2, target: 101}],
          [autoquality: {:ssimulacra2, target: -1}],
          [autoquality: {:butteraugli, target: -1}],
          [autoquality: {:size, allowed_error: 1}],
          [autoquality: {:butteraugli, target: 26}],
          [autoquality: {:ssimulacra2, min_quality: 90, max_quality: 20}],
          [autoquality: {:size, target: 100, target: 200}]
        ] do
      assert_raise ArgumentError, fn -> IP.URL.output(IP.URL.new(), options) end
    end
  end

  for {name, options, path} <- [
        {"resize controls",
         [
           resize: [
             width: 400,
             height: :auto,
             min_width: 200,
             min_height: 100,
             fit: :stretch,
             enlarge: true,
             zoom: {2, 1.5}
           ],
           dpr: 2
         ], "w=400/h=auto/min-w=200/min-h=100/fit=stretch/enlarge/zoom=2,1.5/dpr=2"},
        {"crop geometry",
         [
           crop: {{:pct, 80}, 200},
           crop_ratio: {32, 18},
           crop_ratio_enlarge: true,
           anchor: :top_left,
           anchor_offset: {-10, {:pct, 5}}
         ],
         "crop=80pct,200/crop-ratio=16:9/crop-ratio-enlarge/anchor=top-left/anchor-offset=-10,5pct"},
        {"region and orientation", [rotate: 90.0, flip: :both, region: {5, {:pct, 10}, 100, 80}],
         "rotate=90/flip=hv/region=5,10pct,100,80"},
        {"trim and canvas",
         [
           trim: {"white", 12},
           trim_symmetry: :horizontal,
           resize: [width: 300, height: 200],
           extend: true,
           extend_at: :bottom_right,
           extend_offset: {{:pct, -10}, 20},
           padding: {1, 2, 3},
           background: {{20, 40, 60}, 0.5}
         ],
         "trim=fff,12/trim-symmetry=h/w=300/h=200/extend/extend-at=bottom-right/extend-offset=-10pct,20/pad=1,2,3/bg=14283c,0.5"},
        {"ratio canvas and focus",
         [
           resize: [width: 100, height: 80, fit: :cover],
           focus: {0.3, 0.7},
           extend_ratio: true
         ], "w=100/h=80/fit=cover/focus=0.3,0.7/extend-ratio"},
        {"weighted detection", [crop: {100, 100}, detect: [{:all, 2}, {"face", 3}, "person"]],
         "crop=100,100/detect=all:2,face:3,person"},
        {"progressive blur",
         [progressive_blur: [sigma: 4, direction: -90, start: 0.2, stop: 0.8]],
         "progressive-blur=4,right,0.2,0.8"},
        {"default progressive blur", [progressive_blur: [sigma: 2]], "progressive-blur=2"},
        {"pixel effects",
         [
           blur: 1,
           sharpen: 2,
           pixelate: 3,
           gray: true,
           bitonal: true,
           brightness: -20,
           contrast: 1.2,
           saturation: 0.8
         ],
         "blur=1/sharpen=2/pixelate=3/gray/bitonal/brightness=-20/contrast=1.2/saturation=0.8"},
        {"color effects",
         [
           monochrome: [intensity: 0.2],
           duotone: [intensity: 0.5, shadow: "red", highlight: "blue"],
           colorize: [opacity: 0.4, color: "green", keep_alpha: true],
           gradient: [opacity: 0.7, color: "black", direction: -90, start: 0.2, stop: 0.8]
         ],
         "monochrome=0.2/duotone=0.5,red,blue/colorize=0.4,green,keep-alpha/gradient=0.7,black,270,0.2,0.8"}
      ] do
    test "native and URL #{name} produce the same canonical intent" do
      plan = IP.URL.new() |> IP.URL.group(unquote(Macro.escape(options)))
      assert {:ok, request} = Plan.to_spec(plan.plan)
      assert {:ok, ^request} = parse(unquote(path))
    end
  end

  for {name, options, path} <- [
        {"policy",
         [
           format: :webp,
           quality: 82,
           metadata: :copyright,
           color_profile: {:convert, :display_p3},
           hdr: :preserve
         ], "format=webp/q=82/meta=copyright/profile=display-p3/hdr=preserve"},
        {"quality search",
         [
           autoquality:
             {:ssimulacra2, target: 85, min_quality: 30, max_quality: 95, allowed_error: 1},
           max_bytes: 12_000,
           format_qualities: [webp: 75, jpeg: 90]
         ],
         "autoquality=ssimulacra2,target:85,min:30,max:95,error:1/max-bytes=12000/format-q=webp:75,jpeg:90"},
        {"density", [metadata: :strip, dpi: 300], "meta=strip/dpi=300"},
        {"JPEG",
         [
           format: :jpeg,
           jpeg_options: [
             interlace: true,
             subsample_mode: :off,
             trellis_quant: true,
             overshoot_deringing: true,
             optimize_scans: true,
             quant_table: 3
           ]
         ],
         "format=jpeg/jpeg-options=progressive,subsample:off,trellis-quant,overshoot-deringing,optimize-scans,quant-table:3"},
        {"PNG",
         [
           format: :png,
           png_options: [interlace: true, palette: true, bitdepth: 4, filter: :paeth]
         ], "format=png/png-options=interlace,palette,bitdepth:4,filter:paeth"},
        {"WebP",
         [
           format: :webp,
           webp_options: [
             lossless: true,
             near_lossless: true,
             smart_subsample: true,
             preset: :photo,
             effort: 6
           ]
         ],
         "format=webp/webp-options=lossless,near-lossless,smart-subsample,preset:photo,effort:6"},
        {"AVIF", [format: :avif, avif_options: [subsample_mode: :on, effort: 8]],
         "format=avif/avif-options=subsample:on,effort:8"}
      ] do
    test "native and URL #{name} output settings produce the same sparse policy" do
      plan = IP.URL.new() |> IP.URL.output(unquote(Macro.escape(options)))
      assert {:ok, request} = Plan.to_spec(plan.plan)
      assert {:ok, ^request} = parse(unquote(path))
    end
  end

  test "encoder input boundaries reject malformed fields and preserve sparse false overrides" do
    for {key, field, invalid, url} <- [
          {:jpeg_options, :interlace, "false", "jpeg-options=progressive:true"},
          {:png_options, :bitdepth, 3, "png-options=bitdepth:3"},
          {:webp_options, :effort, 6.0, "webp-options=effort:6.0"},
          {:avif_options, :effort, 10, "avif-options=effort:10"}
        ] do
      assert_raise ArgumentError, fn ->
        IP.URL.new() |> IP.URL.output([{key, [{field, invalid}]}])
      end

      assert {:error, {:invalid_request, [_ | _]}} = parse(url)
    end

    plan = IP.URL.new() |> IP.URL.output(jpeg_options: [interlace: false, quant_table: 0])
    assert {:ok, request} = Plan.to_spec(plan.plan)
    assert {:ok, ^request} = parse("jpeg-options=progressive:false,quant-table:00")
  end

  test "request controls and output overrides retain their scope" do
    plan =
      IP.URL.new(
        orient: :none,
        page: 2,
        filename: "thumb",
        attachment: true,
        cachebuster: "v2",
        expires: 2_000_000_000,
        debug: true
      )
      |> IP.URL.output(webp_options: [lossless: true, effort: 6])
      |> IP.URL.output(webp_options: [effort: 4])

    assert {:ok, request} = Plan.to_spec(plan.plan)

    assert {:ok, ^request} =
             parse(
               "orient=none/page=2/filename=thumb/attachment/cb=v2/expires=2000000000/debug/webp-options=effort:4"
             )
  end

  test "semantic failures agree across the two public input boundaries" do
    for {group, output, path} <- [
          {[resize: [fit: :cover]], [], "fit=cover"},
          {[resize: [width: :auto]], [], "w=auto"},
          {[extend: true], [], "extend"},
          {[trim_symmetry: :both], [], "trim-symmetry=hv"},
          {[crop: {20, 20}, region: {0, 0, 20, 20}], [], "crop=20,20/region=0,0,20,20"},
          {[crop: {20, 20}, anchor: :smart, anchor_offset: {1, 2}], [],
           "crop=20,20/anchor=smart/anchor-offset=1,2"},
          {[blur: 1], [terminal: :blurhash, quality: 80, autoquality: {:ssimulacra2, []}],
           "blur=1/output=blurhash/q=80/autoquality=ssimulacra2"},
          {[blur: 1], [format: :png, max_bytes: 1000], "blur=1/format=png/max-bytes=1000"},
          {[blur: 1], [format: :webp, jpeg_options: [interlace: true]],
           "blur=1/format=webp/jpeg-options=progressive"}
        ] do
      plan = IP.URL.new(@known) |> IP.URL.group(group) |> IP.URL.output(output)
      assert {:error, issues} = IP.URL.validate(plan)
      assert {:error, {:invalid_request, diagnostics}} = parse(path)

      assert Enum.sort(Enum.map(issues, & &1.reason)) ==
               Enum.sort(Enum.map(diagnostics, & &1.reason))
    end
  end

  test "reports conflicts and missing consumers using typed option locations" do
    plan = IP.URL.new(@known) |> IP.URL.group(anchor: :top, focus: {0.5, 0.5})
    assert {:error, issues} = IP.URL.validate(plan)
    assert Enum.any?(issues, &(&1.reason == :mutually_exclusive_options))
    assert Enum.any?(issues, &(&1.reason == :inert_option))
    assert Enum.any?(issues, &({:group, 0, :anchor} in &1.locations))
    assert {:error, ^issues} = Plan.to_spec(plan.plan)
  end

  test "non-image outputs keep image-only options for output validation" do
    plan =
      IP.URL.new()
      |> IP.URL.group(blur: 1)
      |> IP.URL.output(terminal: :lqip_css, format: :webp, quality: 80)

    assert :ok = IP.URL.validate(plan)
    assert IP.URL.url!(plan, "cat.jpg") =~ "format=webp/q=80"

    assert {:ok,
            %Plan.Spec{output: %Plan.Spec.Output{terminal: :lqip_css, format: :webp, quality: 80}}} =
             Plan.to_spec(plan.plan)
  end

  test "info placeholder flags build the same request as the URL" do
    plan = IP.URL.new() |> IP.URL.output(terminal: {:info, [:lqip_css, :blurhash]})
    assert {:ok, request} = Plan.to_spec(plan.plan)
    assert {:ok, ^request} = parse("output=info,blurhash,lqip-css")

    for placeholders <- [[], [:image], [:blurhash, :blurhash]] do
      assert_raise ArgumentError, fn ->
        IP.URL.output(IP.URL.new(), terminal: {:info, placeholders})
      end
    end
  end

  test "checks output conflicts across merged output calls" do
    plan =
      IP.URL.new(@known)
      |> IP.URL.output(quality: 80)
      |> IP.URL.output(autoquality: {:size, target: 12_000})

    assert {:error, [issue]} = IP.URL.validate(plan)
    assert issue.reason == :mutually_exclusive_options

    assert :ok = plan |> IP.URL.output(autoquality: :none) |> IP.URL.validate()
  end

  property "detection defaults and redundant class weights share canonical intent" do
    check all default <- integer(1..100), face <- integer(1..100) do
      selections = [
        {[{:all, default}, {"face", face}], "all:#{default},face:#{face}"},
        {[{"car", default}, {"face", face}, {:all, default}],
         "car:#{default}.0,face:#{face}.0,all:#{default}.0"}
      ]

      weights =
        %{}
        |> then(fn weights ->
          if default == 1, do: weights, else: Map.put(weights, :default, default * 1.0)
        end)
        |> then(fn weights ->
          if face == default, do: weights, else: Map.put(weights, "face", face * 1.0)
        end)

      for {selection, url} <- selections do
        plan = IP.URL.new() |> IP.URL.group(crop: {100, 100}, detect: selection)
        assert {:ok, native} = Plan.to_spec(plan.plan)
        assert {:ok, request} = parse("crop=100,100/detect=" <> url)

        for canonical <- [native, request] do
          assert [group] = canonical.groups
          assert group.guide == {:detect, {:all, weights}}
        end
      end
    end
  end

  property "group keyword order does not change processing intent" do
    check all width <- integer(1..4000), sigma <- integer(0..10) do
      options = [resize: [width: width], trim: :auto, blur: sigma]
      left = IP.URL.new() |> IP.URL.group(options)
      right = IP.URL.new() |> IP.URL.group(Enum.reverse(options))
      assert Plan.to_spec(left.plan) == Plan.to_spec(right.plan)
    end
  end

  defp parse(options) do
    with {:ok, lexed} <- Path.extract("/" <> options <> "/src/photo.jpg", ""),
         do: Parser.parse(lexed, IP.URL.config().options)
  end
end

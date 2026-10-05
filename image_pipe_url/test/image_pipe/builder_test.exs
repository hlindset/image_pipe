defmodule ImagePipe.BuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Spec

  # Semantic checks need to know the mount's presets; this mount has none.
  @known IP.URL.config(validate_against: [])

  test "builds reusable, source-independent plans with explicit groups" do
    plan =
      IP.URL.new(orient: :none)
      |> IP.URL.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart, dpr: 2)
      |> IP.URL.group(trim: :auto, padding: 20, background: "#ffffff")
      |> IP.URL.output(format: :webp, quality: 82)

    assert {:ok, []} = IP.URL.validate(plan)
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

  test "records a malformed value as an error at its location" do
    for {options, location} <- [
          {[resize: [width: 0]], {:group, 0, :width}},
          {[resize: [width: "400"]], {:group, 0, :width}},
          {[blur: -1], {:group, 0, :blur}},
          {[progressive_blur: [sigma: -1]], {:group, 0, :progressive_blur}},
          {[progressive_blur: [sigma: 0, start: 2]], {:group, 0, :progressive_blur}},
          {[progressive_blur: [direction: 90]], {:group, 0, :progressive_blur}},
          {[dpr: 0], {:group, 0, :dpr}},
          {[crop: {0, 20}], {:group, 0, :crop}},
          {[region: {-1, 0, 20, 20}], {:group, 0, :region}},
          {[region: {0, {:pct, -5}, 20, 20}], {:group, 0, :region}},
          {[gray: "true"], {:group, 0, :gray}},
          {[resize: 400], {:group, 0, :resize}},
          {[detect: []], {:group, 0, :detect}},
          {[detect: ["face", "face"]], {:group, 0, :detect}},
          {[detect: [{"face", 0}]], {:group, 0, :detect}},
          {[background: {"red", 2}], {:group, 0, :background}},
          {[gradient: [opacity: 0.5, color: "red", start: -1]], {:group, 0, :gradient}},
          {[gradient: [opacity: 1, color: "red", direction: :sideways]], {:group, 0, :gradient}},
          {[dpr: Integer.pow(10, 400)], {:group, 0, :dpr}},
          {[crop_ratio: {1, Integer.pow(10, 400)}], {:group, 0, :crop_ratio}}
        ] do
      assert [%Spec.Issue{reason: :invalid_value, locations: [^location], severity: :error}] =
               errors(IP.URL.group(IP.URL.new(), options))
    end

    for {options, key} <- [
          {[quality: 101], :quality},
          {[dpi: 0], :dpi},
          {[dpi: 65_536], :dpi},
          {[jpeg_options: [quant_table: 9]], :jpeg_options},
          {[jpeg_options: []], :jpeg_options},
          {[png_options: [bitdepth: 3]], :png_options},
          {[webp_options: [effort: 7]], :webp_options},
          {[format_qualities: []], :format_qualities},
          {[autoquality: 0], :autoquality},
          {[autoquality: 101], :autoquality},
          {[autoquality: :none], :autoquality},
          {[autoquality: {:ssimulacra2, target: 75}], :autoquality},
          {[terminal: {:info, []}], :terminal},
          {[terminal: {:info, [:image]}], :terminal},
          {[terminal: {:info, [:blurhash, :blurhash]}], :terminal}
        ] do
      assert [%Spec.Issue{reason: :invalid_value, locations: [{:request, ^key}]}] =
               errors(IP.URL.output(IP.URL.new(), options))
    end

    assert [%Spec.Issue{reason: :invalid_value, locations: [{:request, :orient}]}] =
             errors(IP.URL.new(orient: :sideways))

    assert [%Spec.Issue{reason: :invalid_value, locations: [{:request, :page}]}] =
             errors(IP.URL.new(page: -1))
  end

  test "records an unknown option name as an error" do
    assert [%Spec.Issue{reason: :unknown_option, locations: [{:group, 0, :mystery}]}] =
             errors(IP.URL.group(IP.URL.new(), mystery: 1))

    assert [%Spec.Issue{reason: :unknown_option, locations: [{:group, 0, :shape}]}] =
             errors(IP.URL.group(IP.URL.new(), resize: [width: 10, shape: :round]))

    assert [%Spec.Issue{reason: :unknown_option, locations: [{:request, :mystery}]}] =
             errors(IP.URL.output(IP.URL.new(), mystery: 1))
  end

  test "a rejected option keeps the rest of the pipeline building" do
    builder =
      IP.URL.new()
      |> IP.URL.group(blur: -1, sharpen: 1)
      |> IP.URL.group(flip: :diag)
      |> IP.URL.output(format: :bmp)

    assert [
             %Spec.Issue{locations: [{:group, 0, :blur}]},
             %Spec.Issue{locations: [{:group, 1, :flip}]},
             %Spec.Issue{locations: [{:request, :format}]}
           ] = errors(builder)

    assert {:error, {:invalid_request, [_, _, _]}} = IP.URL.url(builder, "cat.jpg")
  end

  test "an output option given again replaces its rejected value" do
    builder = IP.URL.new() |> IP.URL.output(quality: 101) |> IP.URL.output(quality: 80)

    assert {:ok, []} = IP.URL.validate(builder)
    assert IP.URL.url!(builder, "cat.jpg") == "/q=80/src/cat.jpg"
  end

  test "a non-keyword argument is a programming error" do
    assert_raise ArgumentError, fn -> IP.URL.group(IP.URL.new(), [1, 2]) end
    assert_raise ArgumentError, fn -> IP.URL.output(IP.URL.new(), :webp) end
  end

  test "a repeated option keeps its last value with a warning" do
    for {options, expected, location} <- [
          {[blur: 1, blur: 2], [blur: 2], {:group, 0, :blur}},
          {[blur: :unset, blur: 2], [blur: 2], {:group, 0, :blur}},
          {[resize: [width: 2, width: 3]], [resize: [width: 3]], {:group, 0, :width}},
          {[resize: [fit: :unset, fit: :cover, width: 1]], [resize: [fit: :cover, width: 1]],
           {:group, 0, :fit}},
          {[monochrome: [intensity: 0.5, intensity: 0.8]], [monochrome: [intensity: 0.8]],
           {:group, 0, :monochrome}}
        ] do
      builder = IP.URL.group(IP.URL.new(), options)

      assert {:ok, [%Spec.Issue{reason: :repeated_option, locations: [^location]} = issue]} =
               IP.URL.validate(builder)

      assert issue.severity == :warning

      assert IP.URL.url!(builder, "a.jpg") ==
               IP.URL.url!(IP.URL.group(IP.URL.new(), expected), "a.jpg")
    end

    builder = IP.URL.output(IP.URL.new(), format_qualities: [webp: 70, webp: 80])

    assert {:ok,
            [%Spec.Issue{reason: :repeated_option, locations: [{:request, :format_qualities}]}]} =
             IP.URL.validate(builder)

    assert IP.URL.url!(builder, "a.jpg") ==
             IP.URL.url!(IP.URL.output(IP.URL.new(), format_qualities: [webp: 80]), "a.jpg")
  end

  test "an empty group is dropped with a warning" do
    expected = IP.URL.new() |> IP.URL.group(blur: 1) |> IP.URL.url!("a.jpg")

    for empty <- [[], [resize: []], [presets: []]] do
      builder = IP.URL.new() |> IP.URL.group(empty) |> IP.URL.group(blur: 1)

      assert {:ok, [%Spec.Issue{reason: :empty_group, locations: [], severity: :warning}]} =
               IP.URL.validate(builder)

      assert IP.URL.url!(builder, "a.jpg") == expected
    end
  end

  test "a repeated or lone leading :unset is written once, with a warning" do
    for {key, value, expected} <- [
          {:jpeg_options, [:unset], :unset},
          {:format_qualities, [:unset], :unset},
          {:jpeg_options, [:unset, :unset, interlace: true], [:unset, interlace: true]},
          {:format_qualities, [:unset, :unset, avif: 50], [:unset, avif: 50]}
        ] do
      builder = IP.URL.output(IP.URL.new(), [{key, value}])

      assert {:ok, [%Spec.Issue{reason: :redundant_unset, locations: [{:request, ^key}]}]} =
               IP.URL.validate(builder)

      assert IP.URL.url!(builder, "a.jpg") ==
               IP.URL.url!(IP.URL.output(IP.URL.new(), [{key, expected}]), "a.jpg")
    end
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
  end

  test "an invalid value's message lists only the values the option accepts" do
    for {builder, expected} <- [
          {IP.URL.group(IP.URL.new(), resize: [width: 300, fit: :fill]),
           "expected one of [:contain, :cover, :stretch, :auto], got: :fill"},
          {IP.URL.group(IP.URL.new(), flip: :diag),
           "expected one of [:horizontal, :vertical, :both], got: :diag"},
          {IP.URL.output(IP.URL.new(), format: :bmp),
           "expected one of [:jpeg, :png, :webp, :avif], got: :bmp"},
          {IP.URL.new(orient: :sideways), "expected one of [:auto, :none], got: :sideways"}
        ] do
      assert [%Spec.Issue{detail: message}] = errors(builder)
      assert message =~ expected
      refute message =~ ":unset"
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
           autoquality: 85,
           max_bytes: 12_000,
           format_qualities: [webp: 75, jpeg: 90]
         ], "autoquality=85/max-bytes=12000/format-q=webp:75,jpeg:90"},
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
      assert [%Spec.Issue{reason: :invalid_value}] =
               errors(IP.URL.new() |> IP.URL.output([{key, [{field, invalid}]}]))

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

  defp reasons({:ok, %Spec{ignored: issues}}),
    do: {:ok, issues |> Enum.map(& &1.reason) |> Enum.sort()}

  defp reasons({:ok, issues}), do: {:ok, issues |> Enum.map(& &1.reason) |> Enum.sort()}
  defp reasons({:error, {:invalid_request, diagnostics}}), do: reasons({:error, diagnostics})
  defp reasons({:error, issues}), do: {:error, issues |> Enum.map(& &1.reason) |> Enum.sort()}

  test "semantic failures agree across the two public input boundaries" do
    for {group, output, path} <- [
          {[resize: [fit: :cover]], [], "fit=cover"},
          {[resize: [width: :auto]], [], "w=auto"},
          {[extend: true], [], "extend"},
          {[trim_symmetry: :both], [], "trim-symmetry=hv"},
          {[crop: {20, 20}, region: {0, 0, 20, 20}], [], "crop=20,20/region=0,0,20,20"},
          {[crop: {20, 20}, anchor: :smart, anchor_offset: {1, 2}], [],
           "crop=20,20/anchor=smart/anchor-offset=1,2"},
          {[blur: 1], [terminal: :blurhash, quality: 80, autoquality: true],
           "blur=1/output=blurhash/q=80/autoquality"},
          {[blur: 1], [format: :png, max_bytes: 1000], "blur=1/format=png/max-bytes=1000"},
          {[blur: 1], [format: :webp, jpeg_options: [interlace: true]],
           "blur=1/format=webp/jpeg-options=progressive"}
        ] do
      plan = IP.URL.new(@known) |> IP.URL.group(group) |> IP.URL.output(output)
      assert reasons(IP.URL.validate(plan)) == reasons(parse(path)), path
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

    assert {:ok, []} = IP.URL.validate(plan)
    assert IP.URL.url!(plan, "cat.jpg") =~ "format=webp/q=80"

    assert {:ok,
            %Plan.Spec{output: %Plan.Spec.Output{terminal: :lqip_css, format: :webp, quality: 80}}} =
             Plan.to_spec(plan.plan)
  end

  test "info placeholder flags build the same request as the URL" do
    plan = IP.URL.new() |> IP.URL.output(terminal: {:info, [:lqip_css, :blurhash]})
    assert {:ok, request} = Plan.to_spec(plan.plan)
    assert {:ok, ^request} = parse("output=info,blurhash,lqip-css")
  end

  test "checks output conflicts across merged output calls" do
    plan =
      IP.URL.new(@known)
      |> IP.URL.output(quality: 80)
      |> IP.URL.output(autoquality: 80)

    assert {:error, [issue]} = IP.URL.validate(plan)
    assert issue.reason == :mutually_exclusive_options

    assert {:ok, []} = plan |> IP.URL.output(autoquality: false) |> IP.URL.validate()
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

  defp errors(builder) do
    assert {:error, issues} = IP.URL.validate(builder)
    issues
  end
end

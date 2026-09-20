defmodule ImagePipe.BuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.Config
  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Plan

  test "builds reusable, source-independent plans with explicit groups" do
    plan =
      IP.new(orient: :none)
      |> IP.group(resize: [width: 400, height: 300, fit: :cover], anchor: :smart, dpr: 2)
      |> IP.group(trim: :auto, padding: 20, background: "#ffffff")
      |> IP.output(format: :webp, quality: 82)

    assert :ok = IP.validate(plan)
    assert {:ok, first} = Plan.to_request(plan, "first.jpg")
    assert {:ok, second} = Plan.to_request(plan, "second.jpg")
    assert first.groups == second.groups
    assert first.source == "first.jpg"
    assert second.source == "second.jpg"
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
    base = IP.new() |> IP.output(format: :webp, quality: 80)
    changed = IP.output(base, quality: 60)
    assert {:ok, original} = Plan.to_request(base, "photo.jpg")
    assert {:ok, updated} = Plan.to_request(changed, "photo.jpg")
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
          [dpr: 0],
          [crop: {0, 20}],
          [gray: "true"],
          [mystery: 1],
          [blur: 1, blur: 2],
          [resize: [width: 2, width: 3]]
        ] do
      assert_raise ArgumentError, fn -> IP.group(IP.new(), options) end
    end

    assert_raise ArgumentError, fn -> IP.output(IP.new(), quality: 101) end
    assert_raise ArgumentError, fn -> IP.new(orient: :sideways) end
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
      assert_raise ArgumentError, fn -> IP.group(IP.new(), options) end
    end

    for options <- [
          [jpeg_options: [quant_table: 9]],
          [png_options: [bitdepth: 3]],
          [webp_options: [effort: 7]],
          [format_qualities: [webp: 70, webp: 80]],
          [autoquality: {:size, target: 0}],
          [autoquality: {:size, allowed_error: 1}],
          [autoquality: {:butteraugli, target: 26}],
          [autoquality: {:ssimulacra2, min_quality: 90, max_quality: 20}],
          [autoquality: {:size, target: 100, target: 200}]
        ] do
      assert_raise ArgumentError, fn -> IP.output(IP.new(), options) end
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
        {"region and orientation", [rotate: 90.0, flip: :both, region: {-5, {:pct, 10}, 100, 80}],
         "rotate=90/flip=hv/region=-5,10pct,100,80"},
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
           resize: [width: 100, height: 80, fit: :cover_down],
           focus: {0.3, 0.7},
           extend_ratio: true
         ], "w=100/h=80/fit=cover-down/focus=0.3,0.7/extend-ratio"},
        {"weighted detection", [crop: {100, 100}, detect: [{:all, 2}, {"face", 3}, "person"]],
         "crop=100,100/detect=all:2,face:3,person"},
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
           gradient: [opacity: 0.7, color: "black", angle: -90, start: 0.2, stop: 0.8]
         ],
         "monochrome=0.2/duotone=0.5,red,blue/colorize=0.4,green,keep-alpha/gradient=0.7,black,270,0.2,0.8"}
      ] do
    test "native and URL #{name} produce the same canonical intent" do
      plan = IP.new() |> IP.group(unquote(Macro.escape(options)))
      assert {:ok, request} = Plan.to_request(plan, "photo.jpg")
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
           format_qualities: [webp: 75, jpeg_xl: 90]
         ],
         "autoquality=ssimulacra2,target:85,min:30,max:95,error:1/max-bytes=12000/format-q=webp:75,jxl:90"},
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
         "format=avif/avif-options=subsample:on,effort:8"},
        {"JXL", [format: :jpeg_xl, jxl_options: [effort: 8]], "format=jxl/jxl-options=effort:8"}
      ] do
    test "native and URL #{name} output settings produce the same sparse policy" do
      plan = IP.new() |> IP.output(unquote(Macro.escape(options)))
      assert {:ok, request} = Plan.to_request(plan, "photo.jpg")
      assert {:ok, ^request} = parse(unquote(path))
    end
  end

  test "request controls and output overrides retain their scope" do
    plan =
      IP.new(
        orient: :none,
        filename: "thumb",
        attachment: true,
        cachebuster: "v2",
        expires: 2_000_000_000,
        debug: true
      )
      |> IP.output(webp_options: [lossless: true, effort: 6])
      |> IP.output(webp_options: [effort: 4])

    assert {:ok, request} = Plan.to_request(plan, "photo.jpg")

    assert {:ok, ^request} =
             parse(
               "orient=none/filename=thumb/attachment/cb=v2/expires=2000000000/debug/webp-options=effort:4"
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
          {[blur: 0], [terminal: :info], "blur=0/output=info"},
          {[blur: 1], [terminal: :blurhash, quality: 80], "blur=1/output=blurhash/q=80"},
          {[blur: 1], [format: :png, max_bytes: 1000], "blur=1/format=png/max-bytes=1000"},
          {[blur: 1], [format: :webp, jpeg_options: [interlace: true]],
           "blur=1/format=webp/jpeg-options=progressive"}
        ] do
      plan = IP.new() |> IP.group(group) |> IP.output(output)
      assert {:error, issues} = IP.validate(plan)
      assert {:error, {:invalid_request, diagnostics}} = parse(path)

      assert Enum.sort(Enum.map(issues, & &1.reason)) ==
               Enum.sort(Enum.map(diagnostics, & &1.reason))
    end
  end

  test "reports conflicts and missing consumers using typed option locations" do
    plan = IP.new() |> IP.group(anchor: :top, focus: {0.5, 0.5})
    assert {:error, issues} = IP.validate(plan)
    assert Enum.any?(issues, &(&1.reason == :mutually_exclusive_options))
    assert Enum.any?(issues, &(&1.reason == :inert_option))
    assert Enum.any?(issues, &({:group, 0, :anchor} in &1.locations))
    assert {:error, ^issues} = Plan.to_request(plan, "photo.jpg")
  end

  test "terminal applicability is checked before no-op normalization" do
    plan = IP.new() |> IP.group(blur: 0) |> IP.output(terminal: :info)
    assert {:error, [issue]} = IP.validate(plan)
    assert issue.reason == :inert_option
    assert issue.locations == [{:group, 0, :blur}]
  end

  test "checks output conflicts across merged output calls" do
    plan = IP.new() |> IP.output(quality: 80) |> IP.output(autoquality: {:size, target: 12_000})
    assert {:error, [issue]} = IP.validate(plan)
    assert issue.reason == :mutually_exclusive_options

    assert :ok = plan |> IP.output(autoquality: :none) |> IP.validate()
  end

  property "group keyword order does not change processing intent" do
    check all width <- integer(1..4000), sigma <- integer(0..10) do
      options = [resize: [width: width], trim: :auto, blur: sigma]
      left = IP.new() |> IP.group(options)
      right = IP.new() |> IP.group(Enum.reverse(options))
      assert Plan.to_request(left, "photo.jpg") == Plan.to_request(right, "photo.jpg")
    end
  end

  defp parse(options) do
    conn = Plug.Test.conn(:get, "/" <> options <> "/src/photo.jpg")
    with {:ok, path} <- Path.extract(conn), do: Parser.parse(path, Config.validate!([]))
  end
end

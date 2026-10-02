defmodule ImagePipe.API.SerializerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.{Parser, Path, Presets, Serializer}
  alias ImagePipe.Plan

  test "ordered groups serialize with a hyphen separator" do
    plan = IP.URL.new() |> IP.URL.group(gray: true) |> IP.URL.group(blur: 1)

    assert segments(plan) == ["gray", "-", "blur=1"]
    assert_round_trip(plan)
  end

  test "canonical requests round trip through every option family" do
    plans = [
      IP.URL.new(),
      IP.URL.new() |> IP.URL.output(jpeg_options: [], webp_options: []),
      IP.URL.new(
        orient: :none,
        page: 0,
        attachment: true,
        filename: "photo",
        cachebuster: "v2",
        expires: 123,
        debug: true
      ),
      IP.URL.new() |> IP.URL.group(rotate: 90, flip: :both, gray: true, bitonal: true, dpr: 2),
      IP.URL.new()
      |> IP.URL.group(
        trim: {"white", 12},
        trim_symmetry: :horizontal,
        region: {-1, 2, {:pct, 80}, 20}
      ),
      IP.URL.new()
      |> IP.URL.group(
        crop: {20, {:pct, 40}},
        anchor: :bottom_right,
        anchor_offset: {2, {:pct, -3}}
      ),
      IP.URL.new()
      |> IP.URL.group(
        crop: {20, 20},
        crop_ratio: {16, 9},
        crop_ratio_enlarge: true,
        focus: {0.1, 0.9}
      ),
      IP.URL.new()
      |> IP.URL.group(
        resize: [
          width: 80,
          height: 60,
          min_width: 20,
          min_height: 10,
          fit: :cover_down,
          enlarge: true,
          zoom: {1.2, 2}
        ],
        anchor: :smart_face
      ),
      IP.URL.new()
      |> IP.URL.group(
        resize: [width: 80, height: 60],
        extend: true,
        extend_at: :top_left,
        extend_offset: {2, {:pct, 5}}
      ),
      IP.URL.new() |> IP.URL.group(resize: [width: 80, height: 60], extend_ratio: true),
      IP.URL.new() |> IP.URL.group(crop: {20, 20}, detect: [:all, {"face", 2}]),
      IP.URL.new() |> IP.URL.group(crop: {20, 20}, detect: ["face", {"dog", 0.5}]),
      IP.URL.new() |> IP.URL.group(crop: {20, 20}, anchor: :smart),
      IP.URL.new()
      |> IP.URL.group(
        blur: 0.2,
        progressive_blur: [sigma: 4, angle: -45, start: 0.2, stop: 0.8],
        sharpen: 1,
        pixelate: 2,
        brightness: -10,
        contrast: 1.5,
        saturation: 0.7
      ),
      IP.URL.new()
      |> IP.URL.group(
        monochrome: [intensity: 0.5, color: "red"],
        duotone: [intensity: 0.3, shadow: "blue", highlight: "white"]
      ),
      IP.URL.new()
      |> IP.URL.group(
        colorize: [opacity: 0.2, color: "green", keep_alpha: true],
        gradient: [opacity: 0.3, color: "black", angle: 35, start: 0.1, stop: 0.8]
      ),
      IP.URL.new() |> IP.URL.group(padding: {1, 2, 3, 4}, background: {"white", 0.5}),
      IP.URL.new()
      |> IP.URL.group(blur: 0)
      |> IP.URL.group(rotate: 360)
      |> IP.URL.group(gray: true),
      IP.URL.new()
      |> IP.URL.output(
        format: :avif,
        quality: 85,
        metadata: :copyright,
        color_profile: {:convert, :display_p3},
        hdr: :tone_map
      ),
      IP.URL.new()
      |> IP.URL.output(
        format_qualities: [jpeg: 70, png: 90],
        autoquality:
          {:ssimulacra2, [target: 85, min_quality: 20, max_quality: 90, allowed_error: 0.3]},
        max_bytes: 50_000
      ),
      IP.URL.new()
      |> IP.URL.output(autoquality: :none, color_profile: :preserve_source, hdr: :preserve),
      IP.URL.new()
      |> IP.URL.output(
        jpeg_options: [
          interlace: true,
          subsample_mode: :off,
          trellis_quant: false,
          overshoot_deringing: true,
          optimize_scans: true,
          quant_table: 3
        ],
        png_options: [interlace: false, palette: true, bitdepth: 8, filter: :paeth]
      ),
      IP.URL.new()
      |> IP.URL.output(
        webp_options: [
          lossless: false,
          near_lossless: true,
          smart_subsample: true,
          preset: :photo,
          effort: 5
        ],
        avif_options: [subsample_mode: :on, effort: 7]
      ),
      IP.URL.new() |> IP.URL.output(terminal: :info),
      IP.URL.new() |> IP.URL.output(terminal: :blurhash),
      IP.URL.new() |> IP.URL.output(terminal: :lqip_css),
      IP.URL.new() |> IP.URL.output(terminal: {:info, [:lqip_css, :blurhash]})
    ]

    Enum.each(plans, &assert_round_trip/1)
  end

  test "explicit identity values survive serialization as preset overrides" do
    first = IP.URL.new() |> IP.URL.group(resize: [width: 50], blur: 0, rotate: 360)
    second = IP.URL.new() |> IP.URL.group(resize: [height: :auto, width: 50, fit: :contain])
    assert "blur=0" in segments(first)
    assert "rotate=0" in segments(first)
    assert "h=auto" in segments(second)
    assert "fit=contain" in segments(second)
    assert_round_trip(first)
    assert_round_trip(second)
  end

  test "preset references serialize first in their own group" do
    {:ok, compiled} =
      Presets.compile(
        %{"mark" => "sharpen=1", "a" => "blur=2", "b" => "format=webp"},
        nil
      )

    plan =
      IP.URL.new()
      |> IP.URL.group(presets: ["mark"], resize: [width: 80])
      |> IP.URL.group(presets: ["a", "b"])
      |> IP.URL.output(quality: 70)

    assert segments(plan) == ["preset=mark", "w=80", "-", "preset=a,b", "q=70"]

    assert {:ok, expected} = Plan.to_spec(plan.plan, compiled.presets)
    path = "/" <> Enum.join(segments(plan) ++ ["src", "photo.jpg"], "/")
    assert {:ok, lexed} = Path.extract(path, "")
    assert {:ok, ^expected} = Parser.parse(lexed, presets: compiled.presets)
  end

  property "geometry and decimal values survive canonical serialization" do
    check all width <- integer(1..4000),
              height <- integer(1..4000),
              dpr <- float(min: 0.01, max: 8.0),
              opacity <- float(min: 0.0, max: 1.0) do
      IP.URL.new()
      |> IP.URL.group(resize: [width: width, height: height], dpr: dpr)
      |> IP.URL.group(colorize: [opacity: opacity, color: "red"])
      |> assert_round_trip()
    end
  end

  test "tiny and large decimals retain their value without exponent notation" do
    for value <- [1.0e-30, 1.0e30, 0.000001, 1.2345678901234567] do
      IP.URL.new() |> IP.URL.group(blur: value) |> assert_round_trip()
    end
  end

  defp segments(plan) do
    Serializer.segments(plan.plan)
  end

  defp assert_round_trip(plan) do
    assert {:ok, expected} = Plan.to_spec(plan.plan)
    path = "/" <> Enum.join(Serializer.segments(plan.plan) ++ ["src", "photo.jpg"], "/")
    assert {:ok, lexed} = Path.extract(path, "")
    assert {:ok, ^expected} = Parser.parse(lexed, presets: %{}), path
  end
end

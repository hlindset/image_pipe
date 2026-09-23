defmodule ImagePipe.API.SerializerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe, as: IP
  alias ImagePipe.API.{Parser, Path, Serializer}
  alias ImagePipe.Plan

  test "ordered groups serialize with a hyphen separator" do
    plan = IP.new() |> IP.group(gray: true) |> IP.group(blur: 1)

    assert segments(plan) == ["gray", "-", "blur=1"]
    assert_round_trip(plan)
  end

  test "canonical requests round trip through every option family" do
    plans = [
      IP.new(),
      IP.new() |> IP.output(jpeg_options: [], webp_options: []),
      IP.new(
        orient: :none,
        attachment: true,
        filename: "photo",
        cachebuster: "v2",
        expires: 123,
        debug: true
      ),
      IP.new() |> IP.group(rotate: 90, flip: :both, gray: true, bitonal: true, dpr: 2),
      IP.new()
      |> IP.group(
        trim: {"white", 12},
        trim_symmetry: :horizontal,
        region: {-1, 2, {:pct, 80}, 20}
      ),
      IP.new()
      |> IP.group(crop: {20, {:pct, 40}}, anchor: :bottom_right, anchor_offset: {2, {:pct, -3}}),
      IP.new()
      |> IP.group(
        crop: {20, 20},
        crop_ratio: {16, 9},
        crop_ratio_enlarge: true,
        focus: {0.1, 0.9}
      ),
      IP.new()
      |> IP.group(
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
      IP.new()
      |> IP.group(
        resize: [width: 80, height: 60],
        extend: true,
        extend_at: :top_left,
        extend_offset: {2, {:pct, 5}}
      ),
      IP.new() |> IP.group(resize: [width: 80, height: 60], extend_ratio: true),
      IP.new() |> IP.group(crop: {20, 20}, detect: [:all, {"face", 2}]),
      IP.new() |> IP.group(crop: {20, 20}, detect: ["face", {"dog", 0.5}]),
      IP.new() |> IP.group(crop: {20, 20}, anchor: :smart),
      IP.new()
      |> IP.group(
        blur: 0.2,
        sharpen: 1,
        pixelate: 2,
        brightness: -10,
        contrast: 1.5,
        saturation: 0.7
      ),
      IP.new()
      |> IP.group(
        monochrome: [intensity: 0.5, color: "red"],
        duotone: [intensity: 0.3, shadow: "blue", highlight: "white"]
      ),
      IP.new()
      |> IP.group(
        colorize: [opacity: 0.2, color: "green", keep_alpha: true],
        gradient: [opacity: 0.3, color: "black", angle: 35, start: 0.1, stop: 0.8]
      ),
      IP.new() |> IP.group(padding: {1, 2, 3, 4}, background: {"white", 0.5}),
      IP.new() |> IP.group(blur: 0) |> IP.group(rotate: 360) |> IP.group(gray: true),
      IP.new()
      |> IP.output(
        format: :avif,
        quality: 85,
        metadata: :copyright,
        color_profile: {:convert, :display_p3},
        hdr: :tone_map
      ),
      IP.new()
      |> IP.output(
        format_qualities: [jpeg: 70, png: 90],
        autoquality:
          {:ssimulacra2, [target: 85, min_quality: 20, max_quality: 90, allowed_error: 0.3]},
        max_bytes: 50_000
      ),
      IP.new() |> IP.output(autoquality: :none, color_profile: :preserve_source, hdr: :preserve),
      IP.new()
      |> IP.output(
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
      IP.new()
      |> IP.output(
        webp_options: [
          lossless: false,
          near_lossless: true,
          smart_subsample: true,
          preset: :photo,
          effort: 5
        ],
        avif_options: [subsample_mode: :on, effort: 7]
      ),
      IP.new() |> IP.output(terminal: :info),
      IP.new() |> IP.output(terminal: :blurhash),
      IP.new() |> IP.output(terminal: :lqip_css)
    ]

    Enum.each(plans, &assert_round_trip/1)
  end

  test "equivalent normalized choices serialize identically" do
    first = IP.new() |> IP.group(resize: [width: 50], blur: 0, rotate: 360)
    second = IP.new() |> IP.group(resize: [height: :auto, width: 50, fit: :contain])
    assert segments(first) == segments(second)
  end

  property "geometry and decimal values survive canonical serialization" do
    check all width <- integer(1..4000),
              height <- integer(1..4000),
              dpr <- float(min: 0.01, max: 8.0),
              opacity <- float(min: 0.0, max: 1.0) do
      IP.new()
      |> IP.group(resize: [width: width, height: height], dpr: dpr)
      |> IP.group(colorize: [opacity: opacity, color: "red"])
      |> assert_round_trip()
    end
  end

  test "tiny and large decimals retain their value without exponent notation" do
    for value <- [1.0e-30, 1.0e30, 0.000001, 1.2345678901234567] do
      IP.new() |> IP.group(blur: value) |> assert_round_trip()
    end
  end

  defp segments(plan) do
    {:ok, request} = Plan.to_request(plan.plan, "photo.jpg")
    Serializer.segments(request)
  end

  defp assert_round_trip(plan) do
    assert {:ok, expected} = Plan.to_request(plan.plan, "photo.jpg")
    path = "/" <> Enum.join(Serializer.segments(expected) ++ ["src", "photo.jpg"], "/")
    assert {:ok, lexed} = Path.extract(Plug.Test.conn(:get, path))
    assert {:ok, ^expected} = Parser.parse(lexed, presets: %{}), path
  end
end

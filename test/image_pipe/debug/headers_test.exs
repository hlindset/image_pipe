defmodule ImagePipe.Debug.HeadersTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Headers
  alias ImagePipe.Debug.Info

  defp header(headers, name), do: List.keyfind(headers, name, 0)

  test "renders source, output, pipeline, cache status and Server-Timing" do
    info = %Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      source_color_space: :srgb,
      source_icc?: true,
      source_bit_depth: 8,
      source_alpha?: false,
      source_orientation: 6,
      shrink: %{w: 2.0, h: 2.0},
      output_format: :avif,
      output_negotiated?: true,
      output_width: 1200,
      output_height: 900,
      output_quality: 72,
      output_stripped?: true,
      output_color_profile: :srgb,
      pipeline: ["scale", "crop"],
      timings: %{decode: 8_000, transform: 21_000, encode: 140_000, total: 181_000}
    }

    headers = Headers.render(info, accept: "image/avif,image/*", cache: :miss)

    assert header(headers, "x-imagepipe-source-format") == {"x-imagepipe-source-format", "jpeg"}
    assert header(headers, "x-imagepipe-source-width") == {"x-imagepipe-source-width", "4000"}
    assert header(headers, "x-imagepipe-source-icc") == {"x-imagepipe-source-icc", "true"}

    assert header(headers, "x-imagepipe-source-orientation") ==
             {"x-imagepipe-source-orientation", "6"}

    assert header(headers, "x-imagepipe-shrink") == {"x-imagepipe-shrink", "w=2.0;h=2.0"}

    assert header(headers, "x-imagepipe-output-format") == {"x-imagepipe-output-format", "avif"}

    assert header(headers, "x-imagepipe-output-negotiated") ==
             {"x-imagepipe-output-negotiated", "true"}

    assert header(headers, "x-imagepipe-output-accept") ==
             {"x-imagepipe-output-accept", "image/avif,image/*"}

    assert header(headers, "x-imagepipe-output-width") == {"x-imagepipe-output-width", "1200"}
    assert header(headers, "x-imagepipe-output-quality") == {"x-imagepipe-output-quality", "72"}

    assert header(headers, "x-imagepipe-pipeline") == {"x-imagepipe-pipeline", "scale,crop"}
    assert header(headers, "x-imagepipe-cache") == {"x-imagepipe-cache", "miss"}

    {"server-timing", server_timing} = header(headers, "server-timing")
    assert server_timing =~ "decode;dur=8.0"
    assert server_timing =~ "transform;dur=21.0"
    assert server_timing =~ "encode;dur=140.0"
    assert server_timing =~ "total;dur=181.0"
  end

  test "omits nil fields" do
    info = %Info{source_format: :png}
    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-source-format") == {"x-imagepipe-source-format", "png"}
    refute header(headers, "x-imagepipe-source-width")
    refute header(headers, "x-imagepipe-output-format")
    refute header(headers, "x-imagepipe-output-accept")
    refute header(headers, "x-imagepipe-output-quality")
  end

  test "renders :default output quality as the \"default\" sentinel" do
    info = %Info{output_format: :jpeg, output_quality: :default}
    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-output-quality") ==
             {"x-imagepipe-output-quality", "default"}
  end

  test "renders autoquality block including per-format quality bounds" do
    info = %Info{
      output_format: :avif,
      aq: %{
        metric: :ssimulacra2,
        score: 78.4,
        target: 78.0,
        min: 60,
        max: 65,
        iterations: 5,
        outcome: :hit,
        limiting_factor: :ceiling,
        scorer: :crop,
        tiles: 9
      }
    }

    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-aq-metric") == {"x-imagepipe-aq-metric", "ssimulacra2"}
    assert header(headers, "x-imagepipe-aq-score") == {"x-imagepipe-aq-score", "78.4"}
    assert header(headers, "x-imagepipe-aq-target") == {"x-imagepipe-aq-target", "78.0"}
    assert header(headers, "x-imagepipe-aq-quality-min") == {"x-imagepipe-aq-quality-min", "60"}
    assert header(headers, "x-imagepipe-aq-quality-max") == {"x-imagepipe-aq-quality-max", "65"}
    assert header(headers, "x-imagepipe-aq-iterations") == {"x-imagepipe-aq-iterations", "5"}
    assert header(headers, "x-imagepipe-aq-outcome") == {"x-imagepipe-aq-outcome", "hit"}

    assert header(headers, "x-imagepipe-aq-limiting-factor") ==
             {"x-imagepipe-aq-limiting-factor", "ceiling"}

    assert header(headers, "x-imagepipe-aq-scorer") == {"x-imagepipe-aq-scorer", "crop"}
    assert header(headers, "x-imagepipe-aq-tiles") == {"x-imagepipe-aq-tiles", "9"}
  end

  test "renders JXL output distance" do
    info = %Info{output_format: :jpeg_xl, output_distance: 1.0}
    headers = Headers.render(info, accept: "", cache: :miss)

    assert header(headers, "x-imagepipe-output-distance") ==
             {"x-imagepipe-output-distance", "1.0"}
  end
end

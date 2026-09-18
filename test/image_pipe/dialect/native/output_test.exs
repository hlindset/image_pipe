defmodule ImagePipe.Native.OutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Native
  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Errors
  alias ImagePipe.Native.Output
  alias ImagePipe.Native.Parser
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.{JpegOptions, WebpOptions}

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp resolve!(segments, host_opts) do
    config = Config.validate!(host_opts)
    assert {:ok, request} = Parser.parse(lexed(segments), config)
    assert {:ok, %PlanOutput{} = output} = Output.resolve(request.output, config)
    output
  end

  test "resolves explicit format and quality over host output defaults" do
    output =
      resolve!(["format=jpeg", "q=42"],
        quality: 71,
        format_quality: %{jpeg: 68}
      )

    assert output.mode == {:explicit, :jpeg}
    assert output.quality == {:quality, 42}
    assert output.default_quality == {:quality, 71}
    assert output.format_qualities.jpeg == {:quality, 68}
  end

  test "explicit quality disables host autoquality" do
    output = resolve!(["q=42"], autoquality_method: :ssimulacra2)

    assert output.quality == {:quality, 42}
    assert output.quality_search == :none
  end

  test "URL autoquality disable overrides the host method" do
    output =
      resolve!(["autoquality=none"],
        autoquality_method: :ssimulacra2,
        autoquality_max_iterations: 4
      )

    assert output.quality_search == :none
    assert output.quality_search_max_iterations == 4
  end

  test "inherits host autoquality when the URL does not select a method" do
    output =
      resolve!(["format=jpeg"],
        autoquality_method: :ssimulacra2,
        autoquality_max_iterations: 5
      )

    assert %PlanOutput.QualitySearch.Ssimulacra2{target: 78} = output.quality_search
    assert output.quality_search_max_iterations == 5
  end

  test "wraps an unresolved host autoquality policy for image output" do
    config = Config.validate!(autoquality_method: :size)
    assert {:ok, request} = Parser.parse(lexed(["format=jpeg"]), config)

    assert {:error, {:invalid_output, {:invalid_option, :autoquality, :missing_target}}} =
             Output.resolve(request.output, config)
  end

  test "URL autoquality selects the method and overlays sparse fields on host defaults" do
    output =
      resolve!(["format=jpeg", "autoquality=ssimulacra2,target:82,min:55,error:0.5"],
        autoquality_method: :butteraugli,
        autoquality_max_quality: 92,
        autoquality_max_resolution: 12
      )

    assert %PlanOutput.QualitySearch.Ssimulacra2{} = search = output.quality_search
    assert search.target == 82
    assert search.url_min_quality == 55
    assert search.url_max_quality == nil
    assert search.max_quality == 92
    assert search.allowed_error == 0.5
    assert search.max_resolution == 12
  end

  test "URL format qualities and encoder options overlay host fields" do
    output =
      resolve!(
        ["format-q=jpeg:61,avif:57", "jpeg-options=progressive,quant-table:3"],
        format_quality: %{jpeg: 68, webp: 74},
        jpeg_options: %JpegOptions{optimize_scans: true}
      )

    assert output.format_qualities.jpeg == {:quality, 61}
    assert output.format_qualities.avif == {:quality, 57}
    assert output.format_qualities.webp == {:quality, 74}

    assert output.encoder_options.jpeg == %JpegOptions{
             interlace: true,
             optimize_scans: true,
             quant_table: 3
           }
  end

  test "explicit quality keeps precedence over a URL format quality" do
    output = resolve!(["format=jpeg", "q=42", "format-q=jpeg:61"], [])
    policy = Policy.from_output_plan(Plug.Test.conn(:get, "/"), output, [])

    assert {:ok, resolved} = Policy.resolve(policy, :jpeg)
    assert resolved.quality == {:quality, 42}
  end

  test "carries a request byte cap" do
    output = resolve!(["format=jpeg", "max-bytes=12000"], [])

    assert output.max_bytes == 12_000
  end

  test "inherits host metadata, color-profile, and HDR policy when URL fields are absent" do
    output =
      resolve!([],
        strip_metadata: false,
        keep_copyright: true,
        strip_color_profile: false,
        preserve_hdr: true
      )

    assert output.strip_metadata == false
    assert output.keep_copyright == false
    assert output.color_profile == :preserve_source
    assert output.hdr == :preserve
  end

  test "URL metadata policy maps to concrete encoder fields" do
    for {value, strip_metadata, keep_copyright} <- [
          {"strip", true, false},
          {"copyright", true, true},
          {"keep", false, false}
        ] do
      output =
        resolve!(["meta=#{value}"],
          strip_metadata: true,
          keep_copyright: true
        )

      assert output.strip_metadata == strip_metadata
      assert output.keep_copyright == keep_copyright
    end
  end

  test "URL profile and HDR policy override host defaults" do
    output =
      resolve!(["profile=display-p3", "hdr=tonemap"],
        strip_color_profile: true,
        preserve_hdr: true
      )

    assert output.color_profile == {:convert, :display_p3}
    assert output.hdr == :tone_map
  end

  test "rejects named profile conversion with effective HDR preservation" do
    config = Config.validate!(preserve_hdr: true)

    assert {:ok, request} = Parser.parse(lexed(["profile=srgb"]), config)

    assert {:error, {:invalid_output, :hdr_profile_conversion}} =
             Output.resolve(request.output, config)

    assert resolve!(["profile=srgb", "hdr=tonemap"], preserve_hdr: true).hdr == :tone_map
  end

  test "rejects URL quality search for an explicit lossless WebP output" do
    for {segments, host_opts} <- [
          {[
             "format=webp",
             "webp-options=lossless",
             "autoquality=ssimulacra2,target:78"
           ], []},
          {["format=webp", "autoquality=ssimulacra2,target:78"],
           [webp_options: %WebpOptions{lossless: true}]},
          {["format=webp", "max-bytes=12000"], [webp_options: %WebpOptions{lossless: true}]}
        ] do
      config = Config.validate!(host_opts)
      assert {:ok, request} = Parser.parse(lexed(segments), config)

      assert {:error, {:invalid_output, :lossless_webp_quality_search}} =
               Output.resolve(request.output, config)
    end
  end

  test "allows inactive inherited search defaults for explicit lossless WebP" do
    output =
      resolve!(["format=webp", "webp-options=lossless"],
        autoquality_method: :ssimulacra2
      )

    assert %PlanOutput.QualitySearch.Ssimulacra2{} = output.quality_search
    assert output.encoder_options.webp.lossless
  end

  test "allows quality controls when automatic negotiation may select another format" do
    output =
      resolve!(
        ["webp-options=lossless", "autoquality=ssimulacra2,target:78", "max-bytes=12000"],
        []
      )

    assert output.mode == :automatic
    assert %PlanOutput.QualitySearch.Ssimulacra2{} = output.quality_search
    assert output.max_bytes == 12_000
  end

  test "blurhash ignores host image output policy" do
    output =
      resolve!(["output=blurhash"],
        autoquality_method: :size,
        strip_metadata: false,
        keep_copyright: false,
        strip_color_profile: false,
        preserve_hdr: true
      )

    assert output == %PlanOutput{mode: :automatic}
  end

  test "prepare captures the resolved output in image negotiation" do
    config = Config.validate!(quality: 71)
    assert {:ok, request} = Parser.parse(lexed(["format=jpeg"]), config)

    assert {:ok, resolved} = Native.prepare(Plug.Test.conn(:get, "/"), request, config)
    assert {:ok, negotiation, _identity} = resolved.negotiation.()

    assert negotiation.plan_output.default_quality == {:quality, 71}
  end

  test "prepare does not resolve image policy for blurhash" do
    config = Config.validate!(autoquality_method: :size)
    assert {:ok, request} = Parser.parse(lexed(["output=blurhash"]), config)

    assert {:ok, resolved} = Native.prepare(Plug.Test.conn(:get, "/"), request, config)
    assert {:ok, negotiation, _identity} = resolved.negotiation.()

    assert negotiation.plan_output == nil
  end

  test "rejects an explicit format's inverted URL and host autoquality bracket" do
    config = Config.validate!(autoquality_max_quality: 80)

    assert {:ok, request} =
             Parser.parse(
               lexed(["format=jpeg", "autoquality=ssimulacra2,min:90"], "ftp://bad"),
               config
             )

    assert {:error, {:invalid_output, {:inverted_autoquality_bracket, :jpeg}}} =
             Native.prepare(Plug.Test.conn(:get, "/"), request, config)
  end

  test "validates every quality-capable format that automatic negotiation may select" do
    config = Config.validate!([])
    assert {:ok, request} = Parser.parse(lexed(["autoquality=ssimulacra2,min:70"]), config)

    assert {:error, {:invalid_output, {:inverted_autoquality_bracket, :avif}}} =
             Native.prepare(Plug.Test.conn(:get, "/"), request, config)
  end

  test "does not validate a modern automatic format disabled by host configuration" do
    config = Config.validate!(auto_avif: false)
    assert {:ok, request} = Parser.parse(lexed(["autoquality=ssimulacra2,min:70"]), config)

    assert {:ok, _resolved} = Native.prepare(Plug.Test.conn(:get, "/"), request, config)
  end

  test "renders resolved-output failures as a safe 400 plan error" do
    reason = {:invalid_output, {:inverted_autoquality_bracket, :jpeg}}
    conn = Errors.send(Plug.Test.conn(:get, "/private/source"), reason, [])

    assert conn.status == 400
    assert conn.resp_body == "invalid output"
    assert Native.classify_error(reason) == :plan_error
  end
end

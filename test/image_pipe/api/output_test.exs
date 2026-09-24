defmodule ImagePipe.API.OutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API
  alias ImagePipe.API.Errors
  alias ImagePipe.API.Parser
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy, as: Output
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.{JpegOptions, WebpOptions}
  alias ImagePipe.Plug.Config

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/cat.jpg") do
    %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}
  end

  defp resolve!(segments, host_opts, accept_header \\ "") do
    config = Config.validate!(host_opts)
    assert {:ok, request} = Parser.parse(lexed(segments), config)
    assert {:ok, output} = Output.resolve(request.output, config, accept_header)
    output
  end

  test "automatic policy negotiates candidates from Accept and varies on Accept" do
    policy = resolve!([], [], "image/webp,image/avif;q=0.1")

    assert policy.mode == :source
    assert policy.modern_candidates == [:avif, :webp]
    assert policy.headers == [{"vary", "Accept"}]
  end

  test "explicit policy is independent of Accept" do
    policy = resolve!(["format=webp"], [], "image/jpeg")

    assert policy.mode == {:explicit, :webp}
    assert policy.modern_candidates == []
    assert policy.headers == []
  end

  test "automatic policy keeps Vary when Accept has no modern format signal" do
    for accept_header <- ["", "*/*", "*/*;q=1", "application/json,*/*;q=1"] do
      policy = resolve!([], [], accept_header)

      assert policy.modern_candidates == []
      assert policy.headers == [{"vary", "Accept"}]
    end
  end

  test "negotiation honors disabled host formats" do
    policy = resolve!([], [auto_avif: false], "image/avif,image/webp")

    assert policy.modern_candidates == [:webp]
  end

  test "encoder options select the resolved format's settings" do
    policy = resolve!(["format=avif", "avif-options=effort:4"], [])

    assert {:ok, resolved} = Policy.resolve(policy, :jpeg)
    assert resolved.encoder_options == %PlanOutput.AvifOptions{effort: 4}
    assert {:ok, resolved} = Policy.resolve(resolve!(["format=avif"], []), :jpeg)
    assert resolved.encoder_options == nil
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

    assert output.format_qualities == %{
             jpeg: {:quality, 68},
             webp: {:quality, 79},
             avif: {:quality, 63}
           }
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
             Output.resolve(request.output, config, "")
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

    assert resolve!([], []).encoder_options == %{}
  end

  test "explicit quality keeps precedence over a URL format quality" do
    output = resolve!(["format=jpeg", "q=42", "format-q=jpeg:61"], [])

    assert {:ok, resolved} = Policy.resolve(output, :jpeg)
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
             Output.resolve(request.output, config, "")

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
               Output.resolve(request.output, config, "")
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

    assert output.mode == :source
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

    assert output == nil
  end

  test "info ignores host image output policy" do
    output =
      resolve!(["output=info"],
        autoquality_method: :size,
        strip_metadata: false,
        keep_copyright: false,
        strip_color_profile: false,
        preserve_hdr: true
      )

    assert output == nil
  end

  test "prepare resolves host output defaults" do
    config = Config.validate!(quality: 71)
    assert {:ok, request} = Parser.parse(lexed(["format=jpeg"]), config)

    assert {:ok, _source, output} = API.prepare(request, "images/cat.jpg", config, "")
    assert output.default_quality == {:quality, 71}
  end

  test "prepare does not resolve image policy for blurhash" do
    config = Config.validate!(autoquality_method: :size)
    assert {:ok, request} = Parser.parse(lexed(["output=blurhash"]), config)

    assert {:ok, _source, output} = API.prepare(request, "images/cat.jpg", config, "")
    assert output == nil
  end

  test "prepare preserves info presentation intent and bypasses image policy" do
    config = Config.validate!(autoquality_method: :size)

    assert {:ok, request} =
             Parser.parse(
               lexed(["output=info", "filename=report", "attachment", "debug"]),
               config
             )

    assert {:ok, _source, output} = API.prepare(request, "images/cat.jpg", config, "")

    assert request.filename == "report"
    assert request.attachment?
    assert request.debug?

    assert output == nil
  end

  test "prepare uses the validated host clock for expiry" do
    config = Config.validate!(clock: fn -> 101 end)
    assert {:ok, request} = Parser.parse(lexed(["expires=100"]), config)

    assert API.prepare(request, "images/cat.jpg", config, "") == {:error, :expired}
  end

  test "rejects an explicit format's inverted URL and host autoquality bracket" do
    config = Config.validate!(autoquality_max_quality: 80)

    assert {:ok, request} =
             Parser.parse(
               lexed(["format=jpeg", "autoquality=ssimulacra2,min:90"], "ftp://bad"),
               config
             )

    assert {:error, {:invalid_output, {:inverted_autoquality_bracket, :jpeg}}} =
             API.prepare(request, "images/cat.jpg", config, "")
  end

  test "validates every quality-capable format that automatic negotiation may select" do
    config = Config.validate!([])
    assert {:ok, request} = Parser.parse(lexed(["autoquality=ssimulacra2,min:70"]), config)

    assert {:error, {:invalid_output, {:inverted_autoquality_bracket, :avif}}} =
             API.prepare(request, "images/cat.jpg", config, "")
  end

  test "does not validate a modern automatic format disabled by host configuration" do
    config = Config.validate!(auto_avif: false)
    assert {:ok, request} = Parser.parse(lexed(["autoquality=ssimulacra2,min:70"]), config)

    assert {:ok, _source, _output} = API.prepare(request, "images/cat.jpg", config, "")
  end

  test "renders resolved-output failures as a safe 400 plan error" do
    reason = {:invalid_output, {:inverted_autoquality_bracket, :jpeg}}
    conn = Errors.send(Plug.Test.conn(:get, "/private/source"), reason)

    assert conn.status == 400
    assert conn.resp_body == "invalid output"
    assert ImagePipe.Telemetry.request_result({:error, reason}) == :plan_error
  end
end

defmodule ImagePipe.API.OutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy, as: Output
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Output.JpegOptions
  alias ImagePipe.Plug.Config
  alias ImagePipe.Plug.Errors
  alias ImagePipe.Plug.Request, as: ParsedRequest

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
    assert resolved.encoder_options == %PlanOutput.AvifOptions{effort: 4, subsample_mode: :off}
    assert {:ok, resolved} = Policy.resolve(resolve!(["format=avif"], []), :jpeg)
    assert resolved.encoder_options == %PlanOutput.AvifOptions{effort: 3, subsample_mode: :off}
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
    assert output.format_qualities == %{}
    assert {:ok, %{quality: {:quality, 42}}} = Policy.resolve(output, :jpeg)
  end

  test "explicit quality disables host autoquality" do
    output = resolve!(["q=42"], autoquality: true)

    assert output.quality == {:quality, 42}
    assert output.quality_search == :none
  end

  test "URL autoquality=false turns off the host default" do
    output = resolve!(["autoquality=false"], autoquality: true)

    assert output.quality_search == :none
  end

  test "inherits host autoquality when the URL does not set it" do
    output = resolve!(["format=jpeg"], autoquality: true)

    assert output.quality_search == %PlanOutput.QualitySearch{target: 75.0}
  end

  test "a bare URL autoquality uses the host target" do
    output = resolve!(["autoquality"], autoquality_target: 80)

    assert %PlanOutput.QualitySearch{target: 80.0} = output.quality_search
  end

  test "a URL target wins over the host target" do
    output = resolve!(["autoquality=82"], autoquality: true, autoquality_target: 70)

    assert %PlanOutput.QualitySearch{target: 82.0} = output.quality_search
  end

  test "URL format qualities and encoder options overlay host fields" do
    output =
      resolve!(
        ["format-q=jpeg:61,avif:57", "jpeg-options=progressive,quant-table:3"],
        format_quality: %{jpeg: 68, webp: 74},
        jpeg_options: [optimize_scans: true]
      )

    assert output.format_qualities.jpeg == {:quality, 61}
    assert output.format_qualities.avif == {:quality, 57}
    assert output.format_qualities.webp == {:quality, 74}

    assert output.encoder_options.jpeg == %JpegOptions{
             interlace: true,
             optimize_scans: true,
             quant_table: 3
           }

    assert resolve!([], []).encoder_options == %{
             avif: %PlanOutput.AvifOptions{effort: 3, subsample_mode: :off}
           }
  end

  test "a URL format quality wins over explicit quality for its format" do
    output = resolve!(["format=jpeg", "q=42", "format-q=jpeg:61"], [])

    assert {:ok, resolved} = Policy.resolve(output, :jpeg)
    assert resolved.quality == {:quality, 61}
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
             "autoquality=78"
           ], []},
          {["format=webp", "autoquality"], [webp_options: [lossless: true]]},
          {["format=webp", "max-bytes=12000"], [webp_options: [lossless: true]]}
        ] do
      config = Config.validate!(host_opts)
      assert {:ok, request} = Parser.parse(lexed(segments), config)

      assert {:error, {:invalid_output, :lossless_webp_quality_search}} =
               Output.resolve(request.output, config, "")
    end
  end

  test "allows inactive inherited search defaults for explicit lossless WebP" do
    output =
      resolve!(["format=webp", "webp-options=lossless"], autoquality: true)

    assert %PlanOutput.QualitySearch{} = output.quality_search
    assert output.encoder_options.webp.lossless
  end

  test "allows quality controls when automatic negotiation may select another format" do
    output =
      resolve!(
        ["webp-options=lossless", "autoquality=78", "max-bytes=12000"],
        []
      )

    assert output.mode == :source
    assert %PlanOutput.QualitySearch{} = output.quality_search
    assert output.max_bytes == 12_000
  end

  test "prepare resolves host output defaults" do
    config = Config.validate!(quality: 71)
    assert {:ok, request} = Parser.parse(lexed(["format=jpeg"]), config)

    assert {:ok, _source, [], output} =
             ParsedRequest.prepare(request, "images/cat.jpg", config, "")

    assert output.default_quality == {:quality, 71}
  end

  test "prepare does not resolve image policy for blurhash" do
    config = Config.validate!(autoquality: true)
    assert {:ok, request} = Parser.parse(lexed(["output=blurhash"]), config)

    assert {:ok, _source, [], output} =
             ParsedRequest.prepare(request, "images/cat.jpg", config, "")

    assert output == nil
  end

  test "prepare preserves info presentation intent and bypasses image policy" do
    config = Config.validate!(autoquality: true)

    assert {:ok, request} =
             Parser.parse(
               lexed(["output=info", "filename=report", "attachment", "debug"]),
               config
             )

    assert {:ok, _source, [], output} =
             ParsedRequest.prepare(request, "images/cat.jpg", config, "")

    assert request.filename == "report"
    assert request.attachment?
    assert request.debug?

    assert output == nil
  end

  test "prepare uses the validated host clock for expiry" do
    config = Config.validate!(clock: fn -> 101 end)
    assert {:ok, request} = Parser.parse(lexed(["expires=100"]), config)

    assert ParsedRequest.prepare(request, "images/cat.jpg", config, "") == {:error, :expired}
  end

  test "renders resolved-output failures as a safe 400 plan error" do
    reason = {:invalid_output, :lossless_webp_quality_search}
    conn = Errors.send(Plug.Test.conn(:get, "/private/source"), reason)

    assert conn.status == 400
    assert conn.resp_body == "invalid output"
    assert ImagePipe.Telemetry.request_result({:error, reason}) == :plan_error
  end
end

defmodule ImagePipe.Parser.Imgproxy.OptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.Imgproxy.Options
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.Presets
  alias ImagePipe.Plan.Color

  test "parses dense pipeline state into one pipeline request" do
    assert {:ok, request} =
             Options.parse(
               ~w(rs:fit:100:0 mw:300 mh:200 z:2:3 dpr:2 c:0.5:0.25:nowe:10:-5 ar:true rot:-90 fl:true:false exar:1),
               Presets.empty()
             )

    [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 100}
    assert pipeline.height == {:pixels, 0}
    assert pipeline.min_width == {:pixels, 300}
    assert pipeline.min_height == {:pixels, 200}
    assert pipeline.zoom_x == 2.0
    assert pipeline.zoom_y == 3.0
    assert pipeline.dpr == 2.0
    assert pipeline.crop.width == {:scale, 0.5}
    assert pipeline.crop.height == {:scale, 0.25}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
    assert request.auto_rotate == true
    assert pipeline.orientation.auto_orient == false
    assert pipeline.orientation.rotate == 270
    assert pipeline.orientation.flip == :horizontal
    assert pipeline.extend_aspect_ratio == true
  end

  test "exar enables aspect-ratio canvas extension with default gravity" do
    assert {:ok, request} = Options.parse(~w(exar:1), Presets.empty())
    [pipeline] = request.pipelines
    assert pipeline.extend_aspect_ratio == true
    assert pipeline.extend_aspect_ratio_gravity == nil
  end

  test "exar:0 disables aspect-ratio canvas extension" do
    assert {:ok, request} = Options.parse(~w(exar:0), Presets.empty())
    [pipeline] = request.pipelines
    assert pipeline.extend_aspect_ratio == false
  end

  test "exar accepts a gravity argument" do
    assert {:ok, request} = Options.parse(~w(exar:1:no), Presets.empty())
    [pipeline] = request.pipelines
    assert pipeline.extend_aspect_ratio == true
    assert pipeline.extend_aspect_ratio_gravity == {:anchor, :center, :top}
  end

  test "exar parses gravity with offsets" do
    assert {:ok, request} = Options.parse(~w(exar:1:no:10:20), Presets.empty())
    [pipeline] = request.pipelines
    assert pipeline.extend_aspect_ratio == true
    assert pipeline.extend_aspect_ratio_gravity == {:anchor, :center, :top}
    assert pipeline.extend_aspect_ratio_x_offset == 10.0
    assert pipeline.extend_aspect_ratio_y_offset == 20.0
  end

  test "exar rejects smart/object gravity" do
    assert {:error, _} = Options.parse(~w(exar:1:sm), Presets.empty())
  end

  test "applies padding and background accumulation against current pipeline state" do
    assert {:ok, request} =
             Options.parse(~w(pd:10:20:30:40 padding:0 bg:f00 bga:0.5), Presets.empty())

    [pipeline] = request.pipelines
    assert pipeline.padding_top == 0
    assert pipeline.padding_right == 0
    assert pipeline.padding_bottom == 0
    assert pipeline.padding_left == 0
    assert %Color{channels: {255, 0, 0}, alpha: {:ratio, 1, 2}} = pipeline.background_color
  end

  describe "padding parsing" do
    test "parses imgproxy padding shorthand into accumulated fields" do
      assert %{padding_top: 10, padding_right: 10, padding_bottom: 10, padding_left: 10} =
               pipeline_for(~w(padding:10))

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 10, padding_left: 20} =
               pipeline_for(~w(padding:10:20))

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 30, padding_left: 20} =
               pipeline_for(~w(padding:10:20:30))

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 30, padding_left: 40} =
               pipeline_for(~w(padding:10:20:30:40))
    end

    test "parses sparse padding with imgproxy accumulated field semantics" do
      assert %{padding_top: 10, padding_right: 10, padding_bottom: 10, padding_left: 10} =
               pipeline_for(~w(padding:10:))

      assert %{padding_top: 0, padding_right: 20, padding_bottom: 0, padding_left: 20} =
               pipeline_for(~w(padding::20))

      assert %{padding_top: 10, padding_right: 10, padding_bottom: 30, padding_left: 10} =
               pipeline_for(~w(padding:10::30))

      assert %{padding_top: 10, padding_right: 5, padding_bottom: 10, padding_left: 5} =
               pipeline_for(~w(pd:10:20:30:40 padding::5))
    end

    test "padding empty and zero forms are accepted by source-compatible parser behavior" do
      assert %{padding_top: 0, padding_right: 0, padding_bottom: 0, padding_left: 0} =
               pipeline_for(~w(padding:))

      assert %{padding_top: 0, padding_right: 0, padding_bottom: 0, padding_left: 0} =
               pipeline_for(~w(pd:10:20:30:40 padding:0))
    end
  end

  describe "background parsing" do
    test "parses decimal and hex background colors into Plan color" do
      assert {:ok, red} = Color.rgb(255, 0, 0)

      assert %{background_color: ^red} = pipeline_for(~w(background:255:0:0))
      assert %{background_color: ^red} = pipeline_for(~w(bg:f00))
      assert %{background_color: ^red} = pipeline_for(~w(bg:FF0000))
    end

    test "empty background clears an accumulated background" do
      assert %{background_color: nil} = pipeline_for(~w(bg:f00 background:))
    end

    test "background alpha applies to the accumulated background color" do
      assert %{background_color: %Color{channels: {255, 0, 0}, alpha: {:ratio, 1, 2}}} =
               pipeline_for(~w(bg:f00 background_alpha:0.5))

      assert %{background_color: %Color{channels: {0, 0, 255}, alpha: {:ratio, 1, 4}}} =
               pipeline_for(~w(bga:0.25 bg:00f))

      assert %{background_color: %Color{channels: {0, 0, 0}, alpha: {:ratio, 1, 2}}} =
               pipeline_for(~w(bga:0.5))
    end

    test "background clear removes accumulated alpha" do
      assert %{background_color: nil} = pipeline_for(~w(bg:f00 bga:0.5 background:))
    end
  end

  test "car parses aspect ratio with default reduce" do
    assert {:ok, %{pipelines: [pipeline]}} = Options.parse(~w(car:1.5), Presets.empty())
    assert pipeline.crop_aspect_ratio == 1.5
    assert pipeline.crop_aspect_ratio_enlarge == false
  end

  test "car parses aspect ratio with enlarge flag" do
    assert {:ok, %{pipelines: [pipeline]}} = Options.parse(~w(car:1:1), Presets.empty())
    assert pipeline.crop_aspect_ratio == 1.0
    assert pipeline.crop_aspect_ratio_enlarge == true
  end

  test "car:0 is a no-op ratio" do
    assert {:ok, %{pipelines: [pipeline]}} = Options.parse(~w(car:0), Presets.empty())
    assert pipeline.crop_aspect_ratio == 0.0
  end

  test "car rejects a negative ratio" do
    assert {:error, _} = Options.parse(~w(car:-1), Presets.empty())
  end

  test "crop gravity is independent from top-level gravity" do
    assert pipeline = pipeline_for(~w(g:so c:0.5:0.25:nowe))

    assert pipeline.gravity == {:anchor, :center, :bottom}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
  end

  test "rotate normalizes integer multiples of 90" do
    for {value, expected} <- [
          {-450, 270},
          {-90, 270},
          {0, 0},
          {90, 90},
          {360, 0},
          {450, 90}
        ] do
      assert pipeline = pipeline_for(["rot:#{value}"])
      assert pipeline.orientation.rotate == expected
    end
  end

  test "flip booleans normalize to explicit orientation intent" do
    assert %{orientation: %{flip: :horizontal}} = pipeline_for(~w(flip:true:false))
    assert %{orientation: %{flip: :vertical}} = pipeline_for(~w(fl:false:true))
    assert %{orientation: %{flip: :both}} = pipeline_for(~w(fl:true:true))
    assert %{orientation: %{flip: nil}} = pipeline_for(~w(fl:false:false))
  end

  test "zoom supports one shared factor or independent axes" do
    assert %{zoom_x: 2.0, zoom_y: 2.0} = pipeline_for(~w(zoom:2))
    assert %{zoom_x: 2.0, zoom_y: 3.0} = pipeline_for(~w(z:2:3))
  end

  test "applies default presets and queued preset groups without changing URL option order semantics" do
    assert {:ok, presets} = Presets.validate_config(%{"default" => "w:100/-/h:200"})
    assert {:ok, request} = Options.parse([], presets)

    assert [first, second] = request.pipelines
    assert first.width == {:pixels, 100}
    assert second.height == {:pixels, 200}
  end

  test "empty segments with no presets produce one default pipeline" do
    assert {:ok, request} = Options.parse([], Presets.empty())
    assert [pipeline] = request.pipelines
    assert pipeline.width == nil
    assert pipeline.height == nil
    assert pipeline.resizing_type == :fit
  end

  test "scoped options accumulate outside the current pipeline" do
    assert {:ok, request} =
             Options.parse(
               ~w(f:webp q:80 fq:jpeg:70 cb:abc exp:999 fn:report att:true),
               Presets.empty()
             )

    assert request.output.format == :webp
    assert request.output.quality == {:quality, 80}
    assert request.output.format_qualities == %{jpeg: {:quality, 70}}
    assert request.cache.cachebuster == "abc"
    assert request.policy.expires == 999
    assert request.response.filename == "report"
    assert request.response.disposition == :attachment
  end

  test "debug option accumulates onto the response map and defaults off" do
    assert {:ok, request} = Options.parse([], Presets.empty())
    assert request.response.debug? == false

    assert {:ok, request} = Options.parse(~w(debug:1), Presets.empty())
    assert request.response.debug? == true
  end

  test "max_bytes and autoquality accumulate onto the output map" do
    assert {:ok, request} =
             Options.parse(
               ~w(mb:51200 autoquality:ssim2:90:70:80:1),
               Presets.empty()
             )

    assert request.output.max_bytes == 51_200

    assert %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{
             target: 90.0,
             min_quality: 70,
             max_quality: 80,
             allowed_error: 1.0
           } = request.output.quality_search
  end

  describe "default quality resolution" do
    @q_defaults [quality: 80, format_quality: %{webp: 79, avif: 63, jpeg_xl: 77}]

    test "config format_quality folds into format_qualities; default_quality from global" do
      assert {:ok, request} = Options.parse([], Presets.empty(), @q_defaults)
      assert request.output.default_quality == {:quality, 80}

      assert request.output.format_qualities == %{
               webp: {:quality, 79},
               avif: {:quality, 63},
               jpeg_xl: {:quality, 77}
             }
    end

    test "URL fq overrides config format_quality for that format" do
      assert {:ok, request} = Options.parse(~w(fq:avif:70), Presets.empty(), @q_defaults)
      assert request.output.format_qualities[:avif] == {:quality, 70}
      assert request.output.format_qualities[:webp] == {:quality, 79}
    end

    test "URL fq:fmt:0 (unset) does not erase the config per-format value" do
      assert {:ok, request} = Options.parse(~w(fq:avif:0), Presets.empty(), @q_defaults)
      assert request.output.format_qualities[:avif] == {:quality, 63}
    end

    test "no config defaults: default_quality stays :default, no synthetic format_qualities" do
      assert {:ok, request} = Options.parse([], Presets.empty(), [])
      assert request.output.default_quality == :default
      assert request.output.format_qualities == %{}
    end
  end

  describe "autoquality resolution" do
    test "bare ssim2 fills target/bracket/allowed_error/per-format from config defaults" do
      defaults = [
        autoquality_target: %{ssimulacra2: 90.0},
        autoquality_min_quality: 70,
        autoquality_max_quality: 80,
        autoquality_allowed_error: %{ssimulacra2: 1.0},
        autoquality_format_min_quality: %{avif: 60},
        autoquality_format_max_quality: %{avif: 65},
        autoquality_max_resolution: 0
      ]

      out = resolve_output(%{quality_search: {:autoquality, [metric: :ssimulacra2]}}, defaults)

      assert %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{} = out.quality_search
      assert out.quality_search.target == 90.0
      assert out.quality_search.min_quality == 70 and out.quality_search.max_quality == 80
      assert out.quality_search.allowed_error == 1.0
      assert out.quality_search.format_min == %{avif: 60}
      assert out.quality_search.format_max == %{avif: 65}
      assert out.quality_search.max_resolution == 0
    end

    test "autoquality:none resolves to :none regardless of config method" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, :disabled}},
          autoquality_method: :ssimulacra2
        )

      assert out.quality_search == :none
    end

    test "absent autoquality falls back to the config method (:none default => off)" do
      out = resolve_output(%{quality_search: :none}, [])
      assert out.quality_search == :none
    end

    test "config method ssimulacra2 with no URL autoquality enables the search from config" do
      defaults = [
        autoquality_method: :ssimulacra2,
        autoquality_target: %{ssimulacra2: 88.0},
        autoquality_min_quality: 70,
        autoquality_max_quality: 80,
        autoquality_allowed_error: %{ssimulacra2: 1.0}
      ]

      out = resolve_output(%{quality_search: :none}, defaults)

      assert %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{target: 88.0} =
               out.quality_search
    end

    test "size method without a target (URL or config) is an invalid option" do
      assert {:error, _} =
               resolve_output_result(
                 %{quality_search: {:autoquality, [metric: :size]}},
                 autoquality_method: :none
               )
    end

    test "ssimulacra2 method without a target (URL or config) defaults to the ssim2 target" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :ssimulacra2]}},
          autoquality_method: :none
        )

      assert %ImagePipe.Plan.Output.QualitySearch.Ssimulacra2{target: 78} = out.quality_search
    end

    test "config autoquality_target overrides the ssim2 default" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :ssimulacra2]}},
          autoquality_target: %{ssimulacra2: 85.0}
        )

      assert out.quality_search.target == 85.0
    end

    test "config size autoquality_target must be a positive integer byte count" do
      for bad <- [0, -1, 1.5] do
        assert {:error, _} =
                 resolve_output_result(
                   %{quality_search: {:autoquality, [metric: :size]}},
                   autoquality_target: %{size: bad}
                 )
      end
    end

    test "config size autoquality_target accepts a positive integer" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :size]}},
          autoquality_target: %{size: 40_000}
        )

      assert %ImagePipe.Plan.Output.QualitySearch.Size{target: 40_000} = out.quality_search
    end

    test "butteraugli method without a target defaults to the butteraugli target" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :butteraugli]}},
          autoquality_method: :none
        )

      assert %ImagePipe.Plan.Output.QualitySearch.Butteraugli{target: 1.0} = out.quality_search
    end
  end

  describe "per-metric autoquality resolution" do
    # Pass the new map-shaped autoquality_allowed_error (%{}) so the OLD code reads
    # the map back as the literal allowed_error (red) until Task 9 lands.
    test "butteraugli without config gets base 70/80 guardrail and 0.1 allowed_error (no 1/100)" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :butteraugli]}},
          autoquality_min_quality: 70,
          autoquality_max_quality: 80,
          autoquality_allowed_error: %{}
        )

      assert %ImagePipe.Plan.Output.QualitySearch.Butteraugli{
               min_quality: 70,
               max_quality: 80,
               allowed_error: 0.1,
               url_min_quality: nil
             } = out.quality_search
    end

    test "ssim2 without config gets 1.0 allowed_error" do
      out =
        resolve_output(
          %{quality_search: {:autoquality, [metric: :ssimulacra2]}},
          autoquality_min_quality: 70,
          autoquality_max_quality: 80,
          autoquality_allowed_error: %{}
        )

      assert out.quality_search.allowed_error == 1.0
    end

    test "config target/allowed_error are read per metric and do not bleed across metrics" do
      defaults = [
        autoquality_target: %{ssimulacra2: 85},
        autoquality_allowed_error: %{ssimulacra2: 0.5},
        autoquality_min_quality: 70,
        autoquality_max_quality: 80
      ]

      ssim = resolve_output(%{quality_search: {:autoquality, [metric: :ssimulacra2]}}, defaults)
      assert ssim.quality_search.target == 85
      assert ssim.quality_search.allowed_error == 0.5

      butt = resolve_output(%{quality_search: {:autoquality, [metric: :butteraugli]}}, defaults)
      assert butt.quality_search.target == 1.0
      assert butt.quality_search.allowed_error == 0.1
    end

    test "URL min/max land on url_min_quality/url_max_quality, base stays config global" do
      out =
        resolve_output(
          %{
            quality_search:
              {:autoquality, [metric: :ssimulacra2, min_quality: 75, max_quality: 85]}
          },
          autoquality_min_quality: 70,
          autoquality_max_quality: 80
        )

      assert out.quality_search.min_quality == 70
      assert out.quality_search.max_quality == 80
      assert out.quality_search.url_min_quality == 75
      assert out.quality_search.url_max_quality == 85
    end
  end

  test "pipeline separators finalize the current pipeline and start the next one" do
    assert {:ok, request} = Options.parse(~w(w:500 - h:200), Presets.empty())

    assert [first, second] = request.pipelines
    assert first.width == {:pixels, 500}
    assert first.height == nil
    assert second.width == nil
    assert second.height == {:pixels, 200}
  end

  test "named presets expand and later URL options can overwrite their fields" do
    assert {:ok, presets} = Presets.validate_config(%{"thumb" => "w:120/h:90"})
    assert {:ok, request} = Options.parse(~w(preset:thumb w:200), presets)

    assert [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 200}
    assert pipeline.height == {:pixels, 90}
  end

  test "recursive presets skip active preset re-entry and keep reachable options" do
    assert {:ok, presets} = Presets.validate_config(%{"loop" => "pr:loop/w:100"})
    assert {:ok, request} = Options.parse(~w(preset:loop), presets)

    assert [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 100}
  end

  test "option and preset errors halt parsing with parser errors" do
    assert Options.parse(~w(preset:missing), Presets.empty()) ==
             {:error, {:unknown_preset, "missing"}}

    assert Options.parse(~w(w), Presets.empty()) ==
             {:error, {:invalid_option_segment, "w"}}

    assert Options.parse(~w(watermark:0.5), Presets.empty()) ==
             {:error, {:unknown_option, "watermark"}}
  end

  defp pipeline_for(option_segments) do
    assert {:ok, request} = Options.parse(option_segments, Presets.empty())
    [pipeline] = request.pipelines
    pipeline
  end

  defp resolve_output(overrides, defaults) do
    assert {:ok, output} = resolve_output_result(overrides, defaults)
    output
  end

  defp resolve_output_result(overrides, defaults) do
    output = ParsedRequest.output_request(overrides)
    Options.resolve_quality_search_defaults(output, defaults)
  end
end

defmodule ImagePipe.Plan.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Request

  test "builds ordered groups from typed intent with independent defaults" do
    request =
      Request.build(
        [%{width: 400, height: 300, fit: :cover, dpr: 2.0}, %{trim: :auto}],
        %{format: :webp, quality: 82},
        "photos/cat.jpg"
      )

    assert [resize, trim] = request.groups
    assert resize.resize.w == 400
    assert resize.resize.h == 300
    assert resize.resize.fit == :cover
    assert resize.guide == {:anchor, :center}
    assert resize.dpr == 2.0
    assert trim.trim == :auto
    assert trim.resize == nil
    assert trim.guide == nil
    assert trim.dpr == 1.0
    assert request.output.format == :webp
    assert request.output.quality == 82
    assert request.source == "photos/cat.jpg"
  end

  test "keeps output policy sparse for host defaults to resolve later" do
    request = Request.build([%{}], %{}, "photos/cat.jpg")

    assert request.orient == :auto
    assert request.output.terminal == :image
    assert request.output.format == nil
    assert request.output.quality == nil
    assert request.output.metadata == nil
    assert request.output.color_profile == nil
    assert request.output.hdr == nil
    assert request.output.autoquality == nil
    assert request.output.encoder_options == %{}
  end

  test "normalizes identity effects and offsets" do
    request =
      Request.build(
        [
          %{
            crop: {{:pct, 50}, {:pct, 100}},
            anchor: :top,
            anchor_offset: {{:pct, 0.0}, {:px, 0}},
            rotate: 0,
            blur: 0.0,
            sharpen: 0.0,
            pixelate: 1,
            brightness: 0,
            contrast: 1.0,
            saturation: 1.0,
            monochrome: %{intensity: 0.0, color: {255, 0, 0}},
            duotone: %{intensity: 0.0, shadow: {0, 0, 0}, highlight: {255, 255, 255}},
            colorize: %{opacity: 0.0, color: {255, 0, 0}, keep_alpha: false},
            gradient: %{opacity: 0.0, color: {255, 0, 0}, angle: 0.0, start: 0.0, stop: 1.0}
          }
        ],
        %{},
        "photos/cat.jpg"
      )

    assert [group] = request.groups
    assert group.crop == {{:pct, 50}, {:pct, 100}}
    assert group.guide == {:anchor, :top}

    for key <- [
          :rotate,
          :anchor_offset,
          :blur,
          :sharpen,
          :pixelate,
          :brightness,
          :contrast,
          :saturation,
          :monochrome,
          :duotone,
          :colorize,
          :gradient
        ] do
      assert Map.fetch!(group, key) == nil
    end
  end

  test "resolves trim, canvas, and background defaults" do
    request =
      Request.build(
        [
          %{
            width: 200,
            height: 300,
            trim: {{255, 255, 255}, nil},
            extend: true,
            extend_offset: {{:pct, 0}, {:px, 10}},
            background: {{255, 255, 255}, nil}
          }
        ],
        %{},
        "photos/cat.jpg"
      )

    assert [group] = request.groups
    assert group.trim == {{255, 255, 255}, 10}
    assert group.canvas == %{mode: :box, at: :center, offset: {{:px, 0}, {:px, 10.0}}}
    assert group.bg == {255, 255, 255, 1.0}
  end

  test "preserves request controls separately from image groups" do
    request =
      Request.build(
        [%{}],
        %{
          orient: :none,
          filename: "portrait",
          attachment: true,
          cachebuster: "revision-2",
          expires: 1_800_000_000,
          debug: true
        },
        "photos/cat.jpg"
      )

    assert request.orient == :none
    assert request.filename == "portrait"
    assert request.attachment?
    assert request.cachebuster == "revision-2"
    assert request.expires == 1_800_000_000
    assert request.debug?
  end

  property "omitted and explicit resize defaults produce the same intent" do
    check all width <- integer(1..4000) do
      implicit = Request.build([%{width: width}], %{}, "photos/cat.jpg")

      explicit =
        Request.build(
          [%{width: width, height: :auto, fit: :contain, enlarge: false, zoom: {1.0, 1.0}}],
          %{},
          "photos/cat.jpg"
        )

      assert implicit == explicit
    end
  end
end

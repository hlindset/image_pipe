defmodule ImagePipe.ImgproxyGenReportTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Constellations
  alias ImagePipe.Test.ImgproxyDifferential.OptsSummary
  alias ImagePipe.Test.ImgproxyDifferential.ReportHtml
  alias Mix.Tasks.Imgproxy.GenReport

  describe "OptsSummary.describe/1" do
    test "resize + gravity" do
      assert OptsSummary.describe("rs:fill:240:180/g:ce") ==
               "resize fill 240×180; gravity center"
    end

    test "compound gravity codes and absolute offset" do
      assert OptsSummary.describe("c:120:90/g:nowe") == "crop 120×90; gravity north-west"

      assert OptsSummary.describe("rs:fill:120:120/g:no:10:20") ==
               "resize fill 120×120; gravity north +10,+20"
    end

    test "trim, min-dims, zoom, dpr" do
      assert OptsSummary.describe("t:10") == "trim (threshold 10)"

      assert OptsSummary.describe("rs:fit:300:300/mw:280/mh:280") ==
               "resize fit 300×300; min-width 280; min-height 280"

      assert OptsSummary.describe("z:0.5") == "zoom 0.5"
      assert OptsSummary.describe("rs:fit:80:80/dpr:2") == "resize fit 80×80; dpr 2"
    end

    test "extend variants" do
      assert OptsSummary.describe("rs:fit:300:200/ex:1") == "resize fit 300×200; extend"

      assert OptsSummary.describe("rs:fit:300:200/ex:1:so") ==
               "resize fit 300×200; extend (south)"

      assert OptsSummary.describe("rs:fit:400:150/ex:1:we:5:0") ==
               "resize fit 400×150; extend (west +5,+0)"

      assert OptsSummary.describe("rs:fit:300:200/exar:1") ==
               "resize fit 300×200; extend-aspect-ratio"
    end

    test "background, blur, sharpen, strip, format, quality" do
      assert OptsSummary.describe("rs:fit:64:64/bg:255:0:0") ==
               "resize fit 64×64; background rgb(255,0,0)"

      assert OptsSummary.describe("rs:fit:240:240/bl:3") == "resize fit 240×240; blur 3"
      assert OptsSummary.describe("rs:fit:240:240/sh:2") == "resize fit 240×240; sharpen 2"

      assert OptsSummary.describe("rs:fit:120:120/sm:1") ==
               "resize fit 120×120; strip-metadata on"

      assert OptsSummary.describe("rs:fit:200:200/scp:0") ==
               "resize fit 200×200; strip-color-profile off"

      assert OptsSummary.describe("rs:fill:240:180/q:40/f:jpg") ==
               "resize fill 240×180; quality 40; format jpg"
    end

    test "padding" do
      assert OptsSummary.describe("rs:fit:120:120/pd:10:20") ==
               "resize fit 120×120; padding 10,20"
    end

    test "unknown segments echo verbatim" do
      assert OptsSummary.describe("rs:fit:64:64/wat:9") == "resize fit 64×64; wat:9"
    end
  end

  defp sample_doc do
    %{
      provenance: %{
        imgproxy_digest: "sha256:abc",
        imgproxy_libvips: "42.20.2",
        pipe_libvips_at_gen: "8.18.2",
        runtime_libvips: "8.18.2"
      },
      cards: [
        %{
          id: "rs_fill_zone",
          group: :transform,
          verdict: :equal,
          url: "/unsafe/rs:fill:240:180/f:png/plain/local:///high_freq.jpg",
          summary: "resize fill 240×180",
          status: :pass,
          flagged?: false,
          failing?: false,
          hash_drift?: false,
          triage: nil,
          tol: nil,
          metric_text: "0 band-bytes over Δ2 (budget 64)",
          imgproxy_img: "data:image/png;base64,AAAA",
          pipe_img: "data:image/png;base64,BBBB",
          heat_banded: "data:image/png;base64,CCCC",
          heat_raw: "data:image/png;base64,DDDD",
          heat_normalized: "data:image/png;base64,NNNN",
          pipe_dims: {240, 180},
          fixture_dims: {240, 180}
        },
        %{
          id: "extend_offset_east_marker",
          group: :transform,
          verdict: :equal,
          url: "/unsafe/rs:fit:400:150/ex:1:ea:20:0/f:png/plain/local:///marker.png",
          summary: "resize fit 400×150; extend (east +20,+0)",
          status: :over_budget,
          flagged?: true,
          # quarantined → noteworthy (flagged) but NOT a lane failure
          failing?: false,
          hash_drift?: false,
          triage: %{reason: "extend east offset sign", issue: "#200"},
          tol: nil,
          metric_text: "9001 band-bytes over Δ2 (budget 64)",
          imgproxy_img: "data:image/png;base64,EEEE",
          pipe_img: "data:image/png;base64,FFFF",
          heat_banded: "data:image/png;base64,GGGG",
          heat_raw: "data:image/png;base64,HHHH",
          heat_normalized: "data:image/png;base64,OOOO",
          pipe_dims: {400, 150},
          fixture_dims: {400, 150}
        },
        %{
          id: "dims_mismatch_marker",
          group: :transform,
          verdict: :equal,
          url: "/unsafe/rs:fit:100:100/f:png/plain/local:///marker.png",
          summary: "resize fit 100×100",
          status: :dims_mismatch,
          flagged?: true,
          failing?: true,
          hash_drift?: false,
          triage: nil,
          tol: nil,
          metric_text: "dims 101×100 ≠ imgproxy 100×100",
          imgproxy_img: "data:image/png;base64,MMMM",
          pipe_img: "data:image/png;base64,PPPP",
          heat_banded: nil,
          heat_raw: nil,
          heat_normalized: nil,
          pipe_dims: {101, 100},
          fixture_dims: {100, 100}
        },
        %{
          id: "lossy_avif",
          group: :lossy,
          verdict: :equal,
          url: "/unsafe/rs:fill:240:180/f:avif/plain/local:///high_freq.jpg",
          summary: "resize fill 240×180; format avif",
          status: :contract_ok,
          flagged?: false,
          failing?: false,
          hash_drift?: false,
          triage: nil,
          tol: nil,
          metric_text:
            "dims 240×180 (expected 240×180); type \"image/avif\" (expected \"image/avif\")",
          imgproxy_img: nil,
          pipe_img: "data:image/avif;base64,IIII",
          heat_banded: nil,
          heat_raw: nil,
          heat_normalized: nil,
          pipe_dims: {240, 180},
          fixture_dims: nil
        }
      ]
    }
  end

  describe "ReportHtml.render/1" do
    test "emits a self-contained document with fonts + slider CDN" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "<!doctype html>"
      assert html =~ "fonts.googleapis.com"
      assert html =~ "img-comparison-slider"
      assert html =~ "Geist"
    end

    test "provenance line labels each version with its scheme and notes incomparability" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "(.so ABI soname)"
      assert html =~ "(release, at gen)"

      # stable fragment only — don't pin the full prose sentence (reword without behavior change)
      assert html =~ "not directly comparable"
      refute html =~ ~s(class="banner skew")
    end

    test "renders a card anchor and metric per case" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(id="rs_fill_zone")
      assert html =~ "0 band-bytes over Δ2 (budget 64)"
      assert html =~ "resize fill 240×180"
    end

    test "triage issue is a clickable repo link" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(href="https://github.com/hlindset/image_pipe/issues/200")
      assert html =~ "extend east offset sign"
    end

    test "counts summary reflects groups and status breakdown" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "3 transform"
      assert html =~ "1 lossy"
      # extend (quarantined over-budget) + dims-mismatch are both flagged; only the
      # non-quarantined dims-mismatch is a lane failure; only extend is quarantined.
      assert html =~ "2 flagged"
      assert html =~ "1 failing"
      assert html =~ "1 quarantined"
    end

    test "lossy card omits imgproxy panel and heatmaps" do
      html = ReportHtml.render(sample_doc())
      refute html =~ "data:image/png;base64,IIII"
      assert html =~ "data:image/avif;base64,IIII"
    end

    test "heatmap modes (banded/raw/normalized) present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(data-heat-set="banded")
      assert html =~ ~s(data-heat-set="raw")
      assert html =~ ~s(data-heat-set="normalized")
      # the normalized heatmap image is inlined on a transform card
      assert html =~ "data:image/png;base64,NNNN"
      assert html =~ "heat-normalized"
    end

    test "status and type filter axes are present and independent" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(data-status-set="all")
      assert html =~ ~s(data-status-set="flagged")
      assert html =~ ~s(data-status-set="failing")
      assert html =~ ~s(data-status-set="quarantined")
      assert html =~ ~s(data-type-set="all")
      assert html =~ ~s(data-type-set="transform")
      assert html =~ ~s(data-type-set="known_divergence")
      assert html =~ ~s(data-type-set="lossy")
      # the body carries both independent axes, defaulting to all/all
      assert html =~ ~s(data-status="all")
      assert html =~ ~s(data-type="all")
      # the type filter actually hides non-matching cards (CSS rule, generated from
      # the axis vocab — not just a button + live count)
      assert html =~ ~s/body[data-type="transform"] .card:not(.group-transform) { display:none; }/
    end

    test "status classes distinguish failing, flagged, and quarantined" do
      html = ReportHtml.render(sample_doc())
      # dims-mismatch is a real lane failure → flagged + failing, not quarantined
      assert html =~ "status-dims_mismatch flagged failing"
      # the quarantined over-budget case is flagged + quarantined, but NOT failing
      assert html =~ "status-over_budget flagged quarantined"
      refute html =~ "status-over_budget flagged failing"
    end

    test "slider panel is capped to the render width" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(class="panel slider" style="width:240px")
    end

    test "filter buttons carry live-count slots and a theme toggle is present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(class="btn-count")
      assert html =~ ~s(id="theme-toggle")
    end
  end

  @tag :imgproxy_report
  test "gen_report renders every constellation to a self-contained file" do
    out =
      Path.join(System.tmp_dir!(), "imgproxy_report_#{System.unique_integer([:positive])}.html")

    on_exit(fn -> File.rm_rf(out) end)

    GenReport.run(["--out", out])

    assert File.exists?(out)
    html = File.read!(out)

    for c <- Constellations.all() do
      assert html =~ ~s(id="#{c.id}"), "report missing card anchor for #{c.id}"
    end

    assert html =~ "band-bytes over Δ", "per-case metric text not rendered"
    assert html =~ "data:image/png;base64,", "no inlined PNG images in report"
    # alpha_resize / background_alpha exercise RGB band-alignment in the heatmap
    # path; the run must not crash on a band-count mismatch.
    assert html =~ "alpha_resize"
    assert html =~ "background_alpha"

    # A triaged parser-gap case (mrd is unimplemented in the ImagePipe parser) renders
    # an ImagePipe error response, not an image. The report must NOT crash on it; it
    # emits a render-error card so the quarantined case is still listed.
    assert html =~ ~s(id="mrd_ceiling_marker"), "render-error case dropped from report"
    assert html =~ "status-render_error", "parser-gap case not marked as a render error"
  end
end

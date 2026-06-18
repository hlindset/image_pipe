defmodule ImagePipe.TwicpicsGenReportTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.TwicpicsDifferential.Constellations
  alias ImagePipe.Test.TwicpicsDifferential.ReportHtml
  alias Mix.Tasks.Twicpics.GenReport

  defp sample_doc do
    %{
      provenance: %{
        twicpics_version: "v1",
        pipe_libvips_at_gen: "8.18.2",
        runtime_libvips: "8.18.2"
      },
      cards: [
        %{
          id: "cover_wide",
          group: :cover,
          verdict: :equal,
          url: "/grid_4x4.png?twic=v1/cover=300x100/output=png",
          summary: "cover=300x100",
          status: :pass,
          flagged?: false,
          failing?: false,
          hash_drift?: false,
          triage: nil,
          divergence: nil,
          tol: nil,
          metric_text: "0 band-bytes over Δ2 (budget 64)",
          oracle_img: "data:image/png;base64,AAAA",
          pipe_img: "data:image/png;base64,BBBB",
          heat_banded: "data:image/png;base64,CCCC",
          heat_raw: "data:image/png;base64,DDDD",
          heat_normalized: "data:image/png;base64,NNNN",
          pipe_dims: {300, 100},
          fixture_dims: {300, 100}
        },
        %{
          id: "cover_ratio_tall",
          group: :cover,
          verdict: :diverges,
          url: "/grid_4x4.png?twic=v1/cover=2:3/output=png",
          summary: "cover=2:3",
          status: :diverges,
          # monitored divergence → noteworthy (flagged), in band → passes the lane
          flagged?: true,
          failing?: false,
          hash_drift?: false,
          triage: nil,
          divergence: %{
            reason: "fractional 2:3 area sub-pixel resampling",
            max_delta: 60..160,
            outliers: 3_000..4_600,
            issue: 331
          },
          tol: nil,
          metric_text: "maxΔ 92 ∈ 60..160, 3869 over Δ2 ∈ 3000..4600 — within band",
          oracle_img: "data:image/png;base64,EEEE",
          pipe_img: "data:image/png;base64,FFFF",
          heat_banded: "data:image/png;base64,GGGG",
          heat_raw: "data:image/png;base64,HHHH",
          heat_normalized: "data:image/png;base64,OOOO",
          pipe_dims: {267, 400},
          fixture_dims: {267, 400}
        },
        %{
          id: "dims_mismatch_case",
          group: :crop,
          verdict: :equal,
          url: "/grid_4x4.png?twic=v1/crop=80x80/output=png",
          summary: "crop=80x80",
          status: :dims_mismatch,
          flagged?: true,
          failing?: true,
          hash_drift?: false,
          triage: nil,
          divergence: nil,
          tol: nil,
          metric_text: "dims 81×80 ≠ TwicPics 80×80",
          oracle_img: "data:image/png;base64,MMMM",
          pipe_img: "data:image/png;base64,PPPP",
          heat_banded: nil,
          heat_raw: nil,
          heat_normalized: nil,
          pipe_dims: {81, 80},
          fixture_dims: {80, 80}
        },
        %{
          id: "quarantined_example",
          group: :inside,
          verdict: :equal,
          url: "/grid_4x4.png?twic=v1/inside=80x80/output=png",
          summary: "inside=80x80",
          status: :over_budget,
          flagged?: true,
          # quarantined → noteworthy (flagged) but NOT a lane failure (excluded)
          failing?: false,
          hash_drift?: false,
          triage: %{reason: "centered 2:3 cover crop divergence", issue: 323},
          divergence: nil,
          tol: nil,
          metric_text: "9001 band-bytes over Δ2 (budget 64)",
          oracle_img: "data:image/png;base64,QQQQ",
          pipe_img: "data:image/png;base64,RRRR",
          heat_banded: "data:image/png;base64,SSSS",
          heat_raw: "data:image/png;base64,TTTT",
          heat_normalized: "data:image/png;base64,UUUU",
          pipe_dims: {80, 80},
          fixture_dims: {80, 80}
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

    test "provenance line carries the TwicPics version and libvips" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "TwicPics <code>v1</code>"
      assert html =~ "ImagePipe libvips <code>8.18.2</code>"
    end

    test "renders a card anchor and metric per case" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(id="cover_wide")
      assert html =~ "0 band-bytes over Δ2 (budget 64)"
      assert html =~ "cover=300x100"
    end

    test "triage issue is a clickable repo link" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(href="https://github.com/hlindset/image_pipe/issues/323")
      assert html =~ "centered 2:3 cover crop divergence"
    end

    test "counts summary reflects groups and status breakdown" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "2 cover"
      assert html =~ "1 crop"
      # cover_ratio_tall (monitored divergence), dims-mismatch, and quarantined_example
      # are all flagged; only the dims-mismatch is a lane failure; only the triaged
      # case is quarantined.
      assert html =~ "3 flagged"
      assert html =~ "1 failing"
      assert html =~ "1 quarantined"
    end

    test "heatmap modes (banded/raw/normalized) present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(data-heat-set="banded")
      assert html =~ ~s(data-heat-set="raw")
      assert html =~ ~s(data-heat-set="normalized")
      # the normalized heatmap image is inlined on a normal card
      assert html =~ "data:image/png;base64,NNNN"
      assert html =~ "heat-normalized"
    end

    test "status and group filter axes are present and independent" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(data-status-set="all")
      assert html =~ ~s(data-status-set="flagged")
      assert html =~ ~s(data-status-set="failing")
      assert html =~ ~s(data-status-set="quarantined")
      assert html =~ ~s(data-type-set="all")
      assert html =~ ~s(data-type-set="focus")
      assert html =~ ~s(data-type-set="cover")
      assert html =~ ~s(data-type-set="crop")
      # cards carry the group via data-group; the body carries both independent axes
      assert html =~ ~s(data-group="cover")
      assert html =~ ~s(data-status="all")
      assert html =~ ~s(data-type="all")
      # the group filter must actually HIDE non-matching cards: the suite's vocab
      # gets a matching CSS hide rule (not just a button + live count). Guards the
      # ReportUI type-axis-css generation against regressing to imgproxy-only vocab.
      assert html =~ ~s/body[data-type="focus"] .card:not(.group-focus) { display:none; }/
      assert html =~ ~s/body[data-type="crop"] .card:not(.group-crop) { display:none; }/
    end

    test "status classes distinguish failing, flagged, and quarantined" do
      html = ReportHtml.render(sample_doc())
      # dims-mismatch is a real lane failure → flagged + failing, not quarantined
      assert html =~ "status-dims_mismatch flagged failing"
      # the quarantined over-budget case is flagged + quarantined, but NOT failing
      assert html =~ "status-over_budget flagged quarantined"
      refute html =~ "status-over_budget flagged failing"
    end

    test "a monitored :diverges card carries the right status, badge, and band note" do
      html = ReportHtml.render(sample_doc())
      # status-diverges class (filterable), flagged but NOT failing/quarantined
      assert html =~ "status-diverges flagged"
      refute html =~ "status-diverges flagged failing"
      # the monitored badge + the band note with a clickable issue link
      assert html =~ ~s(<span class="badge monitored">monitored</span>)
      assert html =~ "monitored divergence"
      assert html =~ "60..160"
      assert html =~ "3000..4600"
      assert html =~ ~s(href="https://github.com/hlindset/image_pipe/issues/331")
      # in-band → the metric reads as ok, not a failure
      assert html =~ ~s(class="metric ok")
    end

    test "slider panel is capped to the render width" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(class="panel slider" style="width:280px")
    end

    test "filter buttons carry live-count slots and a theme toggle is present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(class="btn-count")
      assert html =~ ~s(id="theme-toggle")
    end
  end

  @tag :twicpics_report
  test "gen_report renders every constellation to a self-contained file" do
    out =
      Path.join(System.tmp_dir!(), "twicpics_report_#{System.unique_integer([:positive])}.html")

    on_exit(fn -> File.rm_rf(out) end)

    GenReport.run(["--out", out])

    assert File.exists?(out)
    html = File.read!(out)

    for c <- Constellations.all() do
      assert html =~ ~s(id="#{c.id}"), "report missing card anchor for #{c.id}"
    end

    assert html =~ "band-bytes over Δ", "per-case metric text not rendered"
    assert html =~ "data:image/png;base64,", "no inlined PNG images in report"

    # The monitored `:diverges` divergences are exactly the ones worth eyeballing; the
    # report must keep them, rendered under the monitored (status-diverges) state.
    for id <- ["cover_ratio_tall", "focus_bottomright_cover_ratio"] do
      assert html =~ ~s(id="#{id}"), "monitored divergence #{id} dropped from report"
    end

    assert html =~ "status-diverges", "no card rendered under the monitored :diverges status"
  end
end

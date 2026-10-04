defmodule ImagePipe.Test.ImgproxyReference.Cases do
  @moduledoc """
  Requests whose output is compared against fixtures baked by upstream imgproxy.

  Each case records the native request ImagePipe serves, the imgproxy request
  the fixture was baked from, and the `{threshold, budget}` tolerance: at most
  `budget` band samples may differ by more than `threshold` levels. `:png` cases
  compare decoded pixels; `:lossy` cases compare dimensions and content type.
  Every case also compares the output's structure (content type, band layout,
  depth, ICC profile, orientation and extra metadata) with imgproxy's;
  `:structure_differs` names the fields a case deliberately differs in, with the
  reason. A `:pending` case is skipped with its reason until the named issue is
  fixed.
  See `README.md` next to this file for fixture provenance and change rules.
  """
  use Boundary, top_level?: true, deps: []

  @type t :: %{
          optional(:pending) => String.t(),
          optional(:structure_differs) => %{atom() => String.t()},
          id: String.t(),
          kind: :png | :lossy,
          source: String.t(),
          native: String.t(),
          imgproxy: String.t(),
          tolerance: {non_neg_integer(), non_neg_integer()}
        }

  @spec all() :: [t()]
  def all do
    [
      %{
        id: "rs_fill_zone",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=240/h=180/fit=cover/anchor=center",
        imgproxy: "rs:fill:240:180/g:ce",
        tolerance: {2, 64}
      },
      %{
        id: "rs_fit_zone",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=300/h=300/fit=contain",
        imgproxy: "rs:fit:300:300",
        tolerance: {2, 64}
      },
      %{
        id: "rs_fill_zone_q4",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "rs_fill_webp_residual",
        kind: :png,
        source: "high_freq.webp",
        native: "w=233/h=151/fit=cover",
        imgproxy: "rs:fill:233:151",
        tolerance: {2, 64}
      },
      # Inline-crop placement cases use the aperiodic `:placement` grid, not `:marker`
      # (#239): a no-resize crop of the near-uniform marker field had zero discriminating
      # power (a placement bug moved the window within flat gray → identical pixels). The
      # placement grid's sharp per-cell edges make any 1px window misplacement a maxΔ≈255
      # divergence while the crop stays lossless (maxΔ=0 when correct).
      %{
        id: "crop_gravity_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=120,90/anchor=top-left",
        imgproxy: "c:120:90/g:nowe",
        tolerance: {2, 64}
      },
      # A region's origin is exact: an odd width and height must not move it. imgproxy's
      # north-west crop places the window at its integer pixel offsets
      # (calc_position.go:37-54), so the odd 121×91 window at 37:23 is the same pixels.
      # Lossless crop on the placement grid ⇒ maxΔ=0 when correct; the 1px shift of
      # image_plug-e4a.1.1 is maxΔ≈255.
      %{
        id: "region_odd_origin",
        kind: :png,
        source: "placement.png",
        native: "region=37,23,121,91",
        imgproxy: "c:121:91:nowe:37:23",
        tolerance: {2, 64}
      },
      # Gravity × offset matrix: every imgproxy common gravity type, with and without an
      # x/y offset, as a lossless inline crop on the aperiodic `:placement` grid. Each
      # direction is a distinct `calc_position.go` branch and the offset is applied with a
      # per-edge sign — near edge `pos = offset`, far edge `pos = bounds - crop - offset`,
      # center `centered-base + offset` (calc_position.go:23-54) — so this is realization
      # coverage of the shared `gravity_position` math (same function family as #200's
      # offset clamp), exercised once per branch in the clean no-resample form. Lossless
      # crop ⇒ maxΔ=0 when correct; a 1px placement error is maxΔ≈255 on the grid. Crop
      # 480×360 is non-square so an x/y axis swap can't hide; offset 120:80 is asymmetric
      # and even (no RoundToEven tie) and moves the window inward for every type, so
      # nothing clamps (clamp itself is pinned by #200).
      %{
        id: "grav_ce",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=center",
        imgproxy: "c:480:360:ce",
        tolerance: {2, 64}
      },
      %{
        id: "grav_ce_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=center/anchor-offset=120,80",
        imgproxy: "c:480:360:ce:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_no",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top",
        imgproxy: "c:480:360:no",
        tolerance: {2, 64}
      },
      %{
        id: "grav_no_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top/anchor-offset=120,80",
        imgproxy: "c:480:360:no:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_so",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom",
        imgproxy: "c:480:360:so",
        tolerance: {2, 64}
      },
      %{
        id: "grav_so_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom/anchor-offset=120,80",
        imgproxy: "c:480:360:so:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_ea",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=right",
        imgproxy: "c:480:360:ea",
        tolerance: {2, 64}
      },
      %{
        id: "grav_ea_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=right/anchor-offset=120,80",
        imgproxy: "c:480:360:ea:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_we",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=left",
        imgproxy: "c:480:360:we",
        tolerance: {2, 64}
      },
      %{
        id: "grav_we_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=left/anchor-offset=120,80",
        imgproxy: "c:480:360:we:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_noea",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top-right",
        imgproxy: "c:480:360:noea",
        tolerance: {2, 64}
      },
      %{
        id: "grav_noea_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top-right/anchor-offset=120,80",
        imgproxy: "c:480:360:noea:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_nowe",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top-left",
        imgproxy: "c:480:360:nowe",
        tolerance: {2, 64}
      },
      %{
        id: "grav_nowe_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top-left/anchor-offset=120,80",
        imgproxy: "c:480:360:nowe:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_soea",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom-right",
        imgproxy: "c:480:360:soea",
        tolerance: {2, 64}
      },
      %{
        id: "grav_soea_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom-right/anchor-offset=120,80",
        imgproxy: "c:480:360:soea:120:80",
        tolerance: {2, 64}
      },
      %{
        id: "grav_sowe",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom-left",
        imgproxy: "c:480:360:sowe",
        tolerance: {2, 64}
      },
      %{
        id: "grav_sowe_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=bottom-left/anchor-offset=120,80",
        imgproxy: "c:480:360:sowe:120:80",
        tolerance: {2, 64}
      },
      # Relative-unit offset (|offset| < 1) exercises the `ScaleToEven(bounds·frac)`
      # branch of calc_position.go rather than the `RoundToEven` absolute branch above:
      # 0.1·1600 = 160, 0.05·1200 = 60. Asymmetric so an axis swap still can't hide.
      %{
        id: "grav_ce_rel_off",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=center/anchor-offset=10pct,5pct",
        imgproxy: "c:480:360:ce:0.1:0.05",
        tolerance: {2, 64}
      },
      # Bare-crop gravity-offset inheritance: a `c:W:H` with no inline gravity args takes
      # BOTH the type and the x/y offsets from the top-level `g:` option (imgproxy crop
      # doc: "When gravity is not set, [crop] will use the value of the gravity option").
      # So this must be byte-identical to the inline `grav_no_off` (`c:480:360:no:120:80`)
      # above. imgproxy bakes the offset applied; the comparison probes whether ImagePipe
      # inherits the *offset* (not just the type) for a bare crop.
      %{
        id: "crop_inherit_grav_offset",
        kind: :png,
        source: "placement.png",
        native: "crop=480,360/anchor=top/anchor-offset=120,80",
        imgproxy: "c:480:360/g:no:120:80",
        tolerance: {2, 64}
      },
      # Cross-option interaction edges from docs/imgproxy_processing_graph.md §2 that were
      # implemented but never differentially verified — realization coverage of the
      # relationship branches (the class the bare-crop offset bug above hid in).
      #
      # `ex` dominates `exar`: extend fills the box first (pipeline 10 → 11), so exar
      # early-returns inert (extend.go:7). Must equal extend alone (cf. extend_small).
      %{
        id: "ex_dominates_exar",
        kind: :png,
        source: "small.png",
        native: "w=300/h=200/fit=contain/extend",
        imgproxy: "rs:fit:300:200/ex:1/exar:1",
        tolerance: {2, 64}
      },
      # `zoom` scales target dims but NOT padding (unlike dpr): pd stays 20 under z:1.5
      # (padding.go scales by DprScale only). A leaked zoom→padding scale changes dims.
      %{
        id: "zoom_padding_no_scale",
        kind: :png,
        source: "border.png",
        native: "w=200/h=150/fit=contain/pad=20/zoom=1.5",
        imgproxy: "rs:fit:200:150/pd:20/z:1.5",
        tolerance: {2, 64}
      },
      # `zoom` does NOT scale gravity offsets either (cf. cover_offset_dpr_marker, where
      # dpr DOES). The (10,20) offset must stay put under z:1.5 (mirrors gravity_offset_marker).
      %{
        id: "zoom_offset_no_scale",
        kind: :png,
        source: "marker.png",
        native: "w=120/h=120/fit=cover/zoom=1.5/anchor=top/anchor-offset=10,20",
        imgproxy: "rs:fill:120:120/g:no:10:20/z:1.5",
        tolerance: {2, 64}
      },
      # `dpr` scales ABSOLUTE offsets but not RELATIVE ones (|offset| < 1): the 0.1 offset
      # scales by the result dimension, not by dpr (calc_position.go:23-35). The absolute
      # sibling is cover_offset_dpr_marker.
      %{
        id: "cover_rel_offset_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/dpr=2/anchor=top/anchor-offset=0,10pct",
        imgproxy: "rs:fill:300:200/g:no:0:0.1/dpr:2",
        tolerance: {2, 64}
      },
      # `exar` honors its own gravity slot (default centre): south anchors the image to the
      # bottom of the aspect-ratio canvas. Every other exar case is default-centre.
      %{
        id: "exar_gravity_south_small",
        kind: :png,
        source: "small.png",
        native: "w=200/h=400/fit=contain/extend-ratio/extend-at=bottom",
        imgproxy: "rs:fit:200:400/exar:1:so",
        tolerance: {2, 64}
      },
      # fill-down with target > source: fill-down never upscales (!enlarge), so the
      # asymmetric result-crop branch fires (prepare.go:182-202) and keeps the box's
      # aspect ratio, as fit=cover does without enlarge.
      %{
        id: "fill_down_target_gt_source_small",
        kind: :png,
        source: "small.png",
        native: "w=600/h=400/fit=cover",
        imgproxy: "rs:fill-down:600:400",
        tolerance: {2, 64}
      },
      # Implemented OSS option/forms with no differential coverage (form realization).
      # `size`/`s` (width+height+enlarge+extend, no resizing_type → default fit). The
      # 267×200 fit lands on an odd width whose resample skews the red marker edge
      # (maxΔ 28, ~101 band-bytes, 0 over Δ32 — a real shift would blow past the budget).
      %{
        id: "size_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200",
        imgproxy: "s:300:200",
        tolerance: {2, 256}
      },
      # Single-dimension resize: height 0 = auto (aspect-derived), and standalone `w:`.
      %{
        id: "resize_width_only_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/fit=contain",
        imgproxy: "rs:fit:300:0",
        tolerance: {2, 64}
      },
      %{
        id: "width_only_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300",
        imgproxy: "w:300",
        tolerance: {2, 64}
      },
      # Resize-tail enlarge (4th) + extend (5th) args, vs the standalone `el:`/`ex:` forms.
      %{
        id: "resize_tail_enlarge_extend_small",
        kind: :png,
        source: "small.png",
        native: "w=400/h=400/enlarge/extend/fit=contain",
        imgproxy: "rs:fit:400:400:1:1",
        tolerance: {2, 64}
      },
      # Relative (`< 1` → fraction of source) and full-axis (`0`) crop dimensions.
      %{
        id: "crop_relative_dims_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=50pct,50pct",
        imgproxy: "c:0.5:0.5",
        tolerance: {2, 64}
      },
      %{
        id: "crop_full_axis_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=100pct,600",
        imgproxy: "c:0:600",
        tolerance: {2, 64}
      },
      # #318: fractional crop size on ODD dims hits a `.5` tie (405·0.5 = 202.5,
      # 305·0.5 = 152.5). imgproxy's CalcCropSize rounds crop SIZES half-away-from-zero
      # → 203×153; the old ties-to-even gave 202×152. The divergence surfaces as the
      # output dimensions, so the lossless crop is maxΔ=0 once the size matches.
      %{
        id: "crop_relative_dims_odd_tie",
        kind: :png,
        source: "placement_odd.png",
        native: "crop=50pct,50pct",
        imgproxy: "c:0.5:0.5",
        tolerance: {2, 64}
      },
      # Trim with an explicit background colour (2nd arg) instead of the smart getpoint(0,0):
      # trims the [30,30,30] field, leaving the red marker rect's bounding box.
      %{
        id: "trim_color_marker",
        kind: :png,
        source: "marker.png",
        native: "trim=1e1e1e,10",
        imgproxy: "t:10:1e1e1e",
        tolerance: {2, 64}
      },
      # `bg` hex form (vs the RGB-triple form in background_alpha) — same flatten result.
      %{
        id: "bg_hex_alpha",
        kind: :png,
        source: "alpha.png",
        native: "w=64/h=64/fit=contain/bg=ff0000",
        imgproxy: "rs:fit:64:64/bg:ff0000",
        tolerance: {2, 64}
      },
      # `resizing_type`/`rt` as a standalone option with separate `w:`/`h:`, instead of the
      # meta `rs:type:w:h` — a different parse path that must resolve to the same resize
      # (≡ rs:fit:300:200 → 267×200, same odd-width resample skew as size_marker).
      %{
        id: "resizing_type_direct_marker",
        kind: :png,
        source: "marker.png",
        native: "fit=contain/w=300/h=200",
        imgproxy: "rt:fit/w:300/h:200",
        tolerance: {2, 256}
      },
      %{
        id: "trim_border_equal",
        kind: :png,
        source: "border.png",
        native: "trim=auto",
        imgproxy: "t:10",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_resize",
        kind: :png,
        source: "alpha.png",
        native: "w=64/h=64/fit=contain",
        imgproxy: "rs:fit:64:64",
        tolerance: {2, 64}
      },
      %{
        id: "rotate_exif",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=120/h=120/fit=contain",
        imgproxy: "rs:fit:120:120",
        tolerance: {2, 64}
      },
      %{
        id: "enlarge_small",
        kind: :png,
        source: "small.png",
        native: "w=400/h=400/fit=contain/enlarge",
        imgproxy: "rs:fit:400:400/el:1",
        tolerance: {2, 64}
      },
      # #197: not a placement shift — the differing band-bytes sit in 3 columns at a
      # single sharp red→dark marker edge (max Δ14), with pixels identical on both
      # sides of the edge and the edge at the same x in both. A 1px crop shift would
      # diverge across every edge in the frame (thousands of band-bytes, Δ up to ~210),
      # not 166 at one seam. It is libvips-version anti-aliasing skew at that edge, so
      # the budget is widened (still Δ2; a real crop shift blows far past 256).
      %{
        id: "fill_down_marker",
        kind: :png,
        source: "marker.png",
        native: "w=500/h=500/fit=cover",
        imgproxy: "rs:fill-down:500:500",
        tolerance: {2, 256}
      },
      %{
        id: "gravity_offset_marker",
        kind: :png,
        source: "marker.png",
        native: "w=120/h=120/fit=cover/anchor=top/anchor-offset=10,20",
        imgproxy: "rs:fill:120:120/g:no:10:20",
        tolerance: {2, 64}
      },
      %{
        id: "padding_border",
        kind: :png,
        source: "border.png",
        native: "w=120/h=120/fit=contain/pad=10,20",
        imgproxy: "rs:fit:120:120/pd:10:20",
        tolerance: {2, 64}
      },
      %{
        id: "extend_small",
        kind: :png,
        source: "small.png",
        native: "w=300/h=200/fit=contain/extend",
        imgproxy: "rs:fit:300:200/ex:1",
        tolerance: {2, 64}
      },
      %{
        id: "extend_ar_small",
        kind: :png,
        source: "small.png",
        native: "w=300/h=200/fit=contain/extend-ratio",
        imgproxy: "rs:fit:300:200/exar:1",
        tolerance: {2, 64}
      },
      %{
        id: "dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=80/h=80/fit=contain/dpr=2",
        imgproxy: "rs:fit:80:80/dpr:2",
        tolerance: {2, 64}
      },
      %{
        id: "background_alpha",
        kind: :png,
        source: "alpha.png",
        native: "w=64/h=64/fit=contain/bg=FF0000",
        imgproxy: "rs:fit:64:64/bg:255:0:0",
        tolerance: {2, 64}
      },
      %{
        id: "blur_zone",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=240/h=240/fit=contain/blur=3",
        imgproxy: "rs:fit:240:240/bl:3",
        tolerance: {2, 64}
      },
      %{
        id: "sharpen_zone",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=240/h=240/fit=contain/sharpen=2",
        imgproxy: "rs:fit:240:240/sh:2",
        tolerance: {2, 64}
      },
      %{
        id: "strip_exif",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=120/h=120/fit=contain/meta=strip",
        imgproxy: "rs:fit:120:120/sm:1",
        tolerance: {2, 64}
      },
      # icc_p3 trim agrees with imgproxy in stored pixels; the trim-detection
      # colorspace difference is behavioral-only (not observable here), so this is
      # a pixel reference on a profiled source.
      %{
        id: "trim_icc_p3",
        kind: :png,
        source: "icc_p3.png",
        native: "trim=auto",
        imgproxy: "t:10",
        tolerance: {2, 64}
      },
      # crosses none of these) ---
      #
      # extend + absolute gravity offset + dpr. The source (1600×1200) is LARGER
      # than the requested box, so the fit shrink keeps imgproxy's DprScale at the
      # full 2.0 (a source smaller than the target collapses DprScale to 1.0 under
      # enlarge-off, masking the interaction — see prepare.go calcScale). The
      # integer-clean 400×150 box scales the image to exactly 400×300 (no fractional
      # fit rounding, isolating the dpr interaction from [[extend_ar_dpr_marker]]).
      # imgproxy then dpr-scales BOTH the extend target box — TargetWidth =
      # Scale(400, 2) = 800 (prepare.go:176) — and the absolute west offset —
      # offX = RoundToEven(5 × 2) = 10 (calc_position.go:25-35) — so the canvas is
      # 800×300 with the image at x=10, full height. (West + a horizontally-
      # letterboxed image leaves no vertical room, so the y-offset is held at 0 to
      # avoid imgproxy's calcPosition clamp, which ExtendCanvas does not replicate —
      # tracked under the east/south case [[extend_offset_east_marker]].) ImagePipe
      # threaded neither dpr to the canvas op (it produced a 400×300 canvas at x=5);
      # resolved by carrying the canvas-preserving resize scale into ExtendCanvas,
      # the same way padding does.
      %{
        id: "extend_offset_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=400/h=150/fit=contain/dpr=2/extend/extend-at=left/extend-offset=5,0",
        imgproxy: "rs:fit:400:150/ex:1:we:5:0/dpr:2",
        tolerance: {2, 64}
      },
      # extend + EAST gravity + absolute offset. imgproxy moves the image AWAY from
      # the anchored edge — east: left = width − innerWidth − offX
      # (calc_position.go:44-46) → left = 400 − 200 − 20 = 180 — and clamps the origin
      # to [0, outer − inner] (allowOverflow=false). ExtendCanvas now subtracts the
      # offset for right/bottom anchors and clamps to match (#200).
      %{
        id: "extend_offset_east_marker",
        kind: :png,
        source: "marker.png",
        native: "w=400/h=150/fit=contain/extend/extend-at=right/extend-offset=20,0",
        imgproxy: "rs:fit:400:150/ex:1:ea:20:0",
        tolerance: {2, 64}
      },
      # extend-aspect-ratio + dpr. The AR canvas (600×400) and placement match, and
      # the centred image is now 533px wide (not 534): ImagePipe folds dpr into the
      # single resize scale (round(266.67×2)=533, imath.Scale) instead of rounding the
      # fit dimension first (#199). With the dims aligned the residual is the same
      # libvips-version resampling seam as other sharp marker edges: 201 band-bytes over
      # Δ2 confined to 3 columns (x=100, x=188-190) at sharp marker edges, max Δ28,
      # spread vertically along the edges (a 1px structural shift would instead diverge
      # every edge at near-full contrast — thousands of bytes — and blow the budget).
      # Budget set just above the seam while KEEPING the strict Δ2 threshold.
      %{
        id: "extend_ar_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=contain/dpr=2/extend-ratio",
        imgproxy: "rs:fit:300:200/exar:1/dpr:2",
        tolerance: {2, 256}
      },
      # extend + non-center gravity, no dpr. small (120×90) is smaller than the
      # 300×200 box on both axes, so south gravity has real vertical play: the
      # image lands bottom-centre, not centre. Exercises non-center extend
      # placement without the dpr interaction above.
      %{
        id: "extend_gravity_small",
        kind: :png,
        source: "small.png",
        native: "w=300/h=200/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:300:200/ex:1:so",
        tolerance: {2, 64}
      },
      # cover/fill + min-dims. imgproxy's cropToResult box for the cover path is the
      # literal requested dims (TargetWidth/Height), independent of the mw/mh floor
      # that drove the scale; verifies ImagePipe crops to the same 300×200 box.
      %{
        id: "cover_min_dims_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/min-w=280/min-h=200",
        imgproxy: "rs:fill:300:200/mw:280/mh:200",
        tolerance: {2, 64}
      },
      # padding + dpr. Padding sides scale by dpr (ScaleToEven), the already-covered
      # interaction for extend; the existing padding_border case has no dpr.
      %{
        id: "padding_dpr_border",
        kind: :png,
        source: "border.png",
        native: "w=120/h=120/fit=contain/pad=10,20/dpr=2",
        imgproxy: "rs:fit:120:120/pd:10:20/dpr:2",
        tolerance: {2, 64}
      },
      # #124: with scp:0 ImagePipe now imports the P3 source into the sRGB working
      # space before processing and re-embeds the source profile at finalize, exactly
      # like imgproxy. The colorspace divergence is closed, so this is a pixel-equality
      # conformance case on a Display-P3 source.
      %{
        id: "scp0_colorspace_124",
        kind: :png,
        source: "icc_p3.png",
        native: "w=200/h=200/fit=contain/profile=preserve",
        imgproxy: "rs:fit:200:200/scp:0",
        tolerance: {2, 64}
      },
      #
      # T1.1: EXIF quarter-turn × asymmetric cover. exif_6 is storage 400×300 /
      # display 300×400; the existing rotate_exif is a symmetric fit and can't expose
      # the per-axis storage↔display compensation that an asymmetric cover does.
      %{
        id: "exif_cover_asym",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      # T1.2: EXIF quarter-turn × non-center INLINE crop gravity (c:W:H:TYPE, not the
      # inert result-gravity form). North crop gravity must rotate into the storage
      # frame before the quarter turn.
      %{
        id: "exif_crop_north",
        kind: :png,
        source: "exif_6.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120:no",
        tolerance: {2, 64}
      },
      # T1.3: EXIF × extend with non-center gravity. Extend runs post-orientation-flush
      # in the display frame, fed by the compensated resize dims; south gravity places
      # the fit-scaled image in the 200×200 canvas. The square 200:200 box downscales the
      # rotated block more than the sibling 200:300 extend_so cases, surfacing the same
      # libvips-version downscale skew the landscape exif_2/3/4_extend_so cases show:
      # maxΔ=16, 0 band-bytes over Δ16, image in the correct post-orientation quadrant.
      # Δ32/budget-64 absorbs the version skew (the exif-extend convention) while a 1px
      # block-edge shift (Δ≈160 over the block perimeter) blows the budget.
      %{
        id: "exif_extend_south",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=200/h=200/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:200/ex:1:so",
        tolerance: {32, 64}
      },
      # T1.4: #124 colorspace import compounded with a blur. scp:0 alone is already a
      # PASS (scp0_colorspace_124) since #124 imports the P3 source into the working
      # space before processing, exactly like imgproxy — so the blur runs in the same
      # space on both sides.
      %{
        id: "scp0_blur_icc_p3",
        kind: :png,
        source: "icc_p3.png",
        native: "w=200/h=200/fit=contain/profile=preserve/blur=3",
        imgproxy: "rs:fit:200:200/scp:0/bl:3",
        tolerance: {2, 64}
      },
      # T1.5: alpha-flatten × transparent extend-padding × background. Does the
      # (0,0,0,0) extend padding composite onto bg the same way the source's own alpha
      # does? Forced PNG keeps it pixel-claimable.
      %{
        id: "alpha_extend_bg",
        kind: :png,
        source: "alpha.png",
        native: "w=64/h=64/fit=contain/bg=FF0000/extend",
        imgproxy: "rs:fit:64:64/ex:1/bg:255:0:0",
        tolerance: {2, 64}
      },
      # T1.6: generalize the #199 fit+dpr rounding fold through a SECOND wrapper
      # (extend, not exar) with a fractional fit dim. Since #199 landed (#218) the
      # fit/zoom/dpr fold into one imath.Scale per axis, so this confirms
      # that the fold isn't exar-specific. The residual is the identical libvips-version
      # edge-AA seam as [[extend_ar_dpr_marker]]: 201 band-bytes over Δ2, maxΔ=28, 0 over
      # Δ32 — confined to sharp marker edges. Budget set just above the seam KEEPING the
      # strict Δ2 threshold (a 1px structural shift diverges every edge and blows it).
      %{
        id: "extend_dpr_fractional_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=contain/dpr=2/extend",
        imgproxy: "rs:fit:300:200/ex:1/dpr:2",
        tolerance: {2, 256}
      },
      # T1.7: corner extend compounds #200 on BOTH axes. small (120×90) with enlarge-off
      # stays inside the 400×300 canvas, so the SE-corner offset has real play on the
      # east AND south anchors simultaneously (a marker source fills a 4:3 box exactly,
      # leaving the offset inert) — a stronger pin than the single-axis
      # extend_offset_east_marker. Passes since #200 landed (#218).
      %{
        id: "extend_corner_offset_small",
        kind: :png,
        source: "small.png",
        native: "w=400/h=300/fit=contain/extend/extend-at=bottom-right/extend-offset=20,20",
        imgproxy: "rs:fit:400:300/ex:1:soea:20:20",
        tolerance: {2, 64}
      },
      # #220: the INERT-extend sibling of T1.7. marker (1600×1200, 4:3) fits the
      # 4:3 box exactly (scale 0.25 → 400×300 == the ex:1 target), so the soea
      # offset clamps to 0 and no border is added. imgproxy's extendImage() returns
      # early (`width <= imgWidth && height <= imgHeight`) leaving the untouched
      # 3-band RGB; ExtendCanvas previously still ran Image.embed and emitted 4-band
      # RGBA (a band-layout FINDING, not pixel-comparable). The no-op short-circuit
      # closes it — both sides are now the 3-band fit result, so this pins band parity.
      %{
        id: "extend_inert_marker",
        kind: :png,
        source: "marker.png",
        native: "w=400/h=300/fit=contain/extend/extend-at=bottom-right/extend-offset=20,20",
        imgproxy: "rs:fit:400:300/ex:1:soea:20:20",
        tolerance: {2, 64}
      },
      # T1.8: EXIF-6 ∘ user rot:90 compose (#146 deferred PendingOrientation). After
      # #211/#219 the rotation-primitive seam is gone and the harder transpose/transverse
      # ∘ rot:90 already passes, so this confirms quarter-turn ∘ quarter-turn.
      %{
        id: "exif_user_rot90",
        kind: :png,
        source: "exif_6.jpg",
        native: "rotate=90",
        imgproxy: "rot:90",
        tolerance: {2, 64}
      },
      # T1.9: user-rotate branch of inline crop-gravity compensation — same seam as T1.2
      # but driven by the user rotate input (crop.go adjusts CropGravity for user
      # rotate/flip too). Rotation-primitive seam excluded by #219, so any divergence is
      # genuine CropGravity user-rotate compensation.
      %{
        id: "rot90_crop_north_placement",
        kind: :png,
        source: "placement.png",
        native: "rotate=90/crop=200,120/anchor=top",
        imgproxy: "rot:90/c:200:120:no",
        tolerance: {2, 64}
      },
      #
      # T2.1: inline crop EAST offset — confirms #200 does NOT generalize to the crop
      # path (imgproxy feeds calcPosition→Crop directly with the correct sign).
      %{
        id: "crop_east_offset_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=300,200/anchor=right/anchor-offset=20,0",
        imgproxy: "c:300:200:ea:20:0",
        tolerance: {2, 64}
      },
      # T2.2: cover result-crop SOUTH offset — same #200-non-generalization confirmation
      # for the cropToResult path.
      %{
        id: "cover_gravity_south_offset_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/anchor=bottom/anchor-offset=0,20",
        imgproxy: "rs:fill:300:200/g:so:0:20",
        tolerance: {2, 64}
      },
      # T2.3: focal-point INLINE crop gravity (fp on the crop path, untested in the
      # suite). calc_position ScaleToEven vs crop.ex round-ties-to-even.
      %{
        id: "crop_focal_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=200,200/focus=0.3,0.7",
        imgproxy: "c:200:200:fp:0.3:0.7",
        tolerance: {2, 64}
      },
      # T2.4: odd-gap center origin in the cover result-crop. marker 1600×1200 fill
      # 300×200 cover-scales to 300×225 (gap 25 on height — ODD), center gravity; checks
      # ShrinkToEven(outer−inner+1,2) is wired into result-crop, generalizing #195/#196
      # beyond extend.
      %{
        id: "cover_odd_gap_center_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/anchor=center",
        imgproxy: "rs:fill:300:200/g:ce",
        tolerance: {2, 64}
      },
      # T2.5: trim × shrink-on-load suppression cross. trim nils ImgData before
      # scaleOnLoad, so the fit can't shrink-on-load and resamples from full resolution;
      # tested only in isolation before. Both sides agree on the trimmed box and the fit
      # scale (dims match at 267×200), so the residual is pure resampling-path skew on the
      # zone-plate source — the worst-case resampling cell in the suite. maxΔ=42 (≪ the
      # ~255 a misaligned full-contrast ring would show), spread diffusely across the
      # plate. Threshold set just above that 42 skew ceiling with a tight budget: a
      # structural crop/scale shift misaligns the center rings (maxΔ→~255, thousands of
      # band-bytes) and blows budget 64, while the diffuse AA skew clears it.
      %{
        id: "trim_resize_high_freq",
        kind: :png,
        source: "high_freq.jpg",
        native: "trim=auto/w=300/h=200/fit=contain",
        imgproxy: "t:10/rs:fit:300:200",
        tolerance: {48, 64}
      },
      # T2.7: padding × extend stacking. small + enlarge-off keeps the fit at 120×90, so
      # ex:1 genuinely extends to the 200×150 box (live, not inert) and pd:20 then stacks
      # on top — both canvas ops compose.
      %{
        id: "extend_padding_stack_small",
        kind: :png,
        source: "small.png",
        native: "w=200/h=150/fit=contain/pad=20/extend",
        imgproxy: "rs:fit:200:150/ex:1/pd:20",
        tolerance: {2, 64}
      },
      # T2.8: crop + resize with BOTH gravities live — inline crop gravity north
      # (c:1000:1000:no, the source window) and result gravity south (g:so, the cover
      # window). The most common real shape; zero prior coverage of the two-gravity chain.
      %{
        id: "crop_resize_two_gravities_marker",
        kind: :png,
        source: "marker.png",
        native: "crop=1000,1000/anchor=top/-/w=300/h=200/fit=cover/anchor=bottom",
        imgproxy: "c:1000:1000:no/rs:fill:300:200/g:so",
        tolerance: {2, 64}
      },
      # T2.9: corner gravity on the cover result-crop (calcPosition corner placement).
      %{
        id: "cover_corner_gravity_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=300/fit=cover/anchor=top-right",
        imgproxy: "rs:fill:300:300/g:noea",
        tolerance: {2, 64}
      },
      # T2.10: focal-point on the cover result-crop (fp tested on crop in T2.3; untested
      # on the result-crop site).
      %{
        id: "cover_focal_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=300/fit=cover/focus=0.2,0.8",
        imgproxy: "rs:fill:300:300/g:fp:0.2:0.8",
        tolerance: {2, 64}
      },
      # T2.11: fill-down + non-center (corner) gravity — only center fill-down today.
      # The residual is the identical libvips-version anti-aliasing seam as
      # [[fill_down_marker]]: 166 band-bytes over Δ2 at one sharp marker edge, maxΔ=14,
      # the edge at the same position in both. Strict Δ2 threshold, budget widened just
      # over the seam (a real crop shift blows far past 256).
      %{
        id: "fill_down_corner_gravity_marker",
        kind: :png,
        source: "marker.png",
        native: "w=500/h=500/fit=cover/anchor=bottom-right",
        imgproxy: "rs:fill-down:500:500/g:soea",
        tolerance: {2, 256}
      },
      # T2.12: force resize (stretch; no aspect preservation, no result-crop — a
      # distinct code path), untested entirely.
      %{
        id: "force_resize_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=stretch",
        imgproxy: "rs:force:300:200",
        tolerance: {2, 64}
      },
      # Single-axis stretch keeps the other axis at the source size, so the decode
      # must not shrink on load: imgproxy pre-shrinks by the smaller of the two axis
      # ratios (scale_on_load.go:51), here 1. Shrinking by the width ratio alone decodes
      # 200×150 and stretches it back to 1200 rows, blurring the high-frequency
      # pattern (image_plug-e4a.1.2).
      %{
        id: "force_single_axis_no_preshrink",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=200/fit=stretch",
        imgproxy: "rs:force:200:0",
        tolerance: {2, 64}
      },
      # T2.13: auto resize (picks fit/fill by source vs target orientation), untested
      # entirely. Landscape source into a portrait target.
      %{
        id: "auto_resize_marker",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=300/fit=auto",
        imgproxy: "rs:auto:200:300",
        tolerance: {2, 64}
      },
      # #233: auto resize square↔landscape. imgproxy buckets fill-vs-fit by the SIGN of
      # width−height, with square (diff == 0) in the non-negative (landscape) bucket, so
      # both directions FILL (cover + result-crop) rather than fit. ImagePipe used a
      # three-class (landscape/portrait/square) exact-match classifier that fit these
      # cells; this pins the corrected sign bucketing. Landscape source (1600×1200) into a
      # square target covers to 300×300; square source (512×512) into a landscape target
      # covers to 300×200 (scp:0 strips the P3 profile so only geometry is compared).
      %{
        id: "auto_resize_square_target_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=300/fit=auto",
        imgproxy: "rs:auto:300:300",
        tolerance: {2, 64}
      },
      %{
        id: "auto_resize_square_source_icc",
        kind: :png,
        source: "icc_p3.png",
        native: "w=300/h=200/fit=auto/profile=preserve",
        imgproxy: "rs:auto:300:200/scp:0",
        tolerance: {2, 64}
      },
      # T2.14: inline pre-resize crop corner, no resize — the genuine c:W:H:TYPE corner
      # form on the crop path.
      %{
        id: "crop_corner_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=600,600/anchor=bottom-right",
        imgproxy: "c:600:600:soea",
        tolerance: {2, 64}
      },
      # T2.15: user rot:180 half-turn baseline (no axis swap). De-risked by #211/#219 —
      # the affine primitive seamed even at 180°, now fixed (vips_rot).
      %{
        id: "user_rot180_marker",
        kind: :png,
        source: "marker.png",
        native: "rotate=180",
        imgproxy: "rot:180",
        tolerance: {2, 64}
      },
      # T2.16: horizontal / vertical flip alone (horizontal streams, vertical
      # materializes). fl:1 = horizontal, fl:0:1 = vertical.
      %{
        id: "flip_h_marker",
        kind: :png,
        source: "marker.png",
        native: "flip=h",
        imgproxy: "fl:1",
        tolerance: {2, 64}
      },
      %{
        id: "flip_v_marker",
        kind: :png,
        source: "marker.png",
        native: "flip=v",
        imgproxy: "fl:0:1",
        tolerance: {2, 64}
      },
      # T2.17: user rotate ∘ flip suborder compose (rotation-primitive seam excluded by
      # #219, so a divergence would be genuine suborder).
      %{
        id: "rot90_flip_h_marker",
        kind: :png,
        source: "marker.png",
        native: "rotate=90/flip=h",
        imgproxy: "rot:90/fl:1",
        tolerance: {2, 64}
      },
      # T2.18: EXIF-6 ∘ user-flip compose (flip never used the affine path, so
      # unaffected by #211/#219 — this exercises the EXIF ∘ user-flip suborder directly).
      %{
        id: "exif_user_flip_h",
        kind: :png,
        source: "exif_6.jpg",
        native: "flip=h",
        imgproxy: "fl:1",
        tolerance: {2, 64}
      },
      # extend, smart pre-resize crop) ---
      #
      # Cases filling anchor × site cells that #203 left open.
      # The placement bugs that motivated the table (#194 cropToResult box, #195/#196
      # extend center origin, #200 extend offset sign/clamp) are all fixed and every
      # anchor/site is exercised somewhere, so a divergence here is a genuine
      # site-specific calcPosition bug, not yield.
      #
      # West on the pre-resize crop site (c:W:H:TYPE). placement 1600×1200, a 300×200
      # window anchored west → left=0, vertically centered (top=500). West has 1300px of
      # horizontal play here, so a left/center confusion shifts the window across the
      # placement grid's sharp per-cell edges (maxΔ→~255) — unlike the cover/extend sites
      # whose box aspect can leave the west anchor inert. (On the old `:marker` source
      # this window sat in the flat gray field and discriminated nothing — #239.)
      %{
        id: "crop_west_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=300,200/anchor=left",
        imgproxy: "c:300:200:we",
        tolerance: {2, 64}
      },
      # West on the cover result-crop site (rs:fill/g:TYPE). The box is PORTRAIT (200×300)
      # so the cover surplus is horizontal: marker 4:3 covers 200×300 at scale 0.25 →
      # 400×300, and the 200-wide result-crop has 200px of horizontal play. West → left=0
      # (the left half of the cover). A landscape box (e.g. 300×200) leaves only vertical
      # surplus, making west inert — so the box puts the west anchor on a live axis.
      %{
        id: "cover_west_gravity_marker",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=300/fit=cover/anchor=left",
        imgproxy: "rs:fill:200:300/g:we",
        tolerance: {2, 64}
      },
      # North on the extend site — the exact vertical mirror of [[extend_gravity_small]]
      # (south). small (120×90) with enlarge-off stays 120×90 inside the 300×200 canvas,
      # so north has real vertical play (110px) and anchors the image to the top (y=0),
      # not the centre. extend already covers south/east/west/soea but never the top.
      %{
        id: "extend_gravity_north_small",
        kind: :png,
        source: "small.png",
        native: "w=300/h=200/fit=contain/extend/extend-at=top",
        imgproxy: "rs:fit:300:200/ex:1:no",
        tolerance: {2, 64}
      },
      # Smart (attention) crop on the pre-resize crop site (c:W:H:sm). The two libvips
      # versions pick the SAME salient window on the sharp marker source — the bake is an
      # exact match (maxΔ=0), so it holds at the strict default Δ2/64. Smart crop is still
      # attention-skew-prone (the #203 T3.8 caveat), so a future regression here is most
      # likely a libvips-version attention difference picking a different window: that is a
      # structural divergence to investigate, never a tolerance to
      # widen.
      %{
        id: "crop_smart_marker",
        kind: :png,
        source: "marker.png",
        native: "crop=300,300/anchor=smart",
        imgproxy: "c:300:300:sm",
        tolerance: {2, 64}
      },
      #
      # Before #224 the suite exercised only `blur` and `sharpen` of the stage-9
      # `applyFilters` family. `pixelate` (`pix`) is the one remaining OSS-supported
      # effect — imgproxy's `apply_filters.go` applies exactly {blur, sharpen,
      # pixelate}; brightness/contrast/saturation/monochrome/duotone are imgproxy-Pro
      # (absent from the OSS `darthsim/imgproxy` container's option keys), so they are
      # not differential gaps and stay out of this suite, like `cp`/`icc`. `pix:8` on
      # the sharp-edged marker is the same vips_shrink (box mean) + vips_zoom (nearest)
      # both sides run — ImagePipe matches imgproxy's `vips.c` `apply_filters` exactly
      # (#238), so the output is byte-identical (maxΔ=0). A box mean is bounded by the
      # source range and cannot ring, so the former (Δ2, Δ16] residual — wrongly blamed
      # on block-average rounding / libvips skew — was entirely the prior Lanczos
      # down-step overshooting the marker edge. Default Δ2/64; a real block-offset
      # (~210 at the sharp edge) blows it.
      %{
        id: "pixelate_marker",
        kind: :png,
        source: "marker.png",
        native: "pixelate=8",
        imgproxy: "pix:8",
        tolerance: {2, 64}
      },
      # The OSS-valid effects-chain ORDER pin. The issue's pix→br→co→sa form is Pro
      # (br/co/sa), but the three OSS filters stack in a fixed stage-9 order both
      # sides share — imgproxy `apply_filters.go`/`vips.c` runs blur → sharpen →
      # pixelate, and ImagePipe's `effect_operations` emits the same blur → sharpen →
      # pixelate (URL option order is inert; the plan fixes it). Stacking all three on
      # the zone-plate source pins that ordering end-to-end: a reordered chain (e.g.
      # pixelate before blur/sharpen) would composite a grossly different image (maxΔ
      # into the 100s across the frame). With the box-mean pixelate (#238) the chain is
      # byte-identical to imgproxy (maxΔ=0) — the former Δ36 residual was the Lanczos
      # pixelate ringing on the zone plate, not blur/sharpen skew. Default Δ2/64.
      %{
        id: "effects_chain_order_high_freq",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=240/h=240/fit=contain/blur=2/sharpen=2/pixelate=8",
        imgproxy: "rs:fit:240:240/bl:2/sh:2/pix:8",
        tolerance: {2, 64}
      },
      #
      # cmyk.jpg is a 120×90 CMYK JPEG. `rs:fit:200:200` is a no-op resize (fit
      # without enlarge leaves the smaller source unscaled), so the pixel claim is the
      # PURE stage-4 colorspaceToProcessing CMYK→sRGB working-space import — no
      # resampling confound. The import is unconditional (support-matrix stage 4), and
      # distinct from `cp:cmyk` CMYK *output* targeting (#214).
      %{
        id: "cmyk_import",
        kind: :png,
        source: "cmyk.jpg",
        native: "w=200/h=200/fit=contain",
        imgproxy: "rs:fit:200:200",
        tolerance: {2, 64}
      },
      # rgb16/rgba16 are 512×512 16-bit PNGs whose content spans the FULL 16-bit range
      # (white corner + saturated highlight block in the high bits, #240); the prior
      # sources held 8-bit values in a 16-bit buffer (~0.4% intensity), so they rendered
      # near-black and the preserve-vs-tonemap split was barely exercised. `ph:1`
      # preserves the high bit-depth through to the PNG output (the #121 preserve-HDR
      # path), `ph:0` tone-maps to 8-bit — the two halves of the HDR pipeline. The
      # 512→200 fit genuinely downscales (averaging full-range neighbors produces real
      # full-precision 16-bit low-byte data), so each is import + 16-bit (or tone-mapped)
      # resample + PNG round-trip. The alpha source additionally exercises the 16-bit
      # RGBA path.
      %{
        id: "rgb16_preserve_hdr",
        kind: :png,
        source: "rgb16.png",
        native: "hdr=preserve/w=200/h=200/fit=contain",
        imgproxy: "ph:1/rs:fit:200:200",
        tolerance: {2, 64}
      },
      %{
        id: "rgb16_tonemap_8bit",
        kind: :png,
        source: "rgb16.png",
        native: "hdr=tonemap/w=200/h=200/fit=contain",
        imgproxy: "ph:0/rs:fit:200:200",
        tolerance: {2, 64}
      },
      # rgba16_preserve_hdr is the rgb16 preserve case plus a 16-bit alpha band — the
      # 16-bit RGBA preserve-HDR path. The source alpha is uniformly opaque (65535);
      # ImagePipe leaves it untouched, while imgproxy premultiplies the RGB by the
      # alpha before the resize and rounds the alpha a hair off 65535, nudging a few
      # RGB(A) samples. The decoded footprint is a handful of sub-tolerance skew
      # samples (maxΔ ~9 levels, well inside the default Δ2/64 tol), on par with the
      # rgba16 tonemap sibling below — so it passes the default tolerance.
      %{
        id: "rgba16_preserve_hdr",
        kind: :png,
        source: "rgba16.png",
        native: "hdr=preserve/w=200/h=200/fit=contain",
        imgproxy: "ph:1/rs:fit:200:200",
        tolerance: {2, 64}
      },
      %{
        id: "rgba16_tonemap_8bit",
        kind: :png,
        source: "rgba16.png",
        native: "hdr=tonemap/w=200/h=200/fit=contain",
        imgproxy: "ph:0/rs:fit:200:200",
        tolerance: {2, 64}
      },
      # Each is a PRODUCT of two independently-correct compensations; the halves are
      # covered in isolation but their interaction is not.
      #
      # P1: focal-point gravity × EXIF orientation. orientation.ex rotates {:fp,fx,fy}
      # coords into the storage frame (rotate_fp / flip-fraction rules), but only the
      # CARDINAL-anchor rotation has differential coverage (exif_crop_north,
      # rot90_crop_north_marker) — the fp coordinate-rotation path has none. exif_6 is a
      # plain quarter turn; 5/7 (transpose/transverse) add an axis swap to the fraction.
      # Inline crop on the aperiodic exif_placement grid (#239 EXIF half): the focal
      # window would land in exif_base's uniform gold ground, so a fp-rotation bug would
      # move it within a flat field; the placement grid makes any 1px shift maxΔ≈255.
      %{
        id: "exif_crop_focal",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "crop=200,120/focus=0.3,0.7",
        imgproxy: "c:200:120:fp:0.3:0.7",
        tolerance: {2, 64}
      },
      %{
        id: "exif_cover_focal_transpose",
        kind: :png,
        source: "exif_5.jpg",
        native: "w=200/h=150/fit=cover/focus=0.2,0.8",
        imgproxy: "rs:fill:200:150/g:fp:0.2:0.8",
        tolerance: {2, 64}
      },
      %{
        id: "exif_cover_focal_transverse",
        kind: :png,
        source: "exif_7.jpg",
        native: "w=200/h=150/fit=cover/focus=0.2,0.8",
        imgproxy: "rs:fill:200:150/g:fp:0.2:0.8",
        tolerance: {2, 64}
      },
      # P3: absolute offset × dpr on the cover and inline-crop sites. Offset-scales-by-
      # dpr (ScaleToEven) is baked ONLY on the extend site (extend_offset_dpr_marker);
      # the cover result-crop and inline-crop offsets are baked without dpr
      # (cover_gravity_south_offset_marker, crop_east_offset_placement).
      %{
        id: "cover_offset_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/dpr=2/anchor=bottom/anchor-offset=0,20",
        imgproxy: "rs:fill:300:200/g:so:0:20/dpr:2",
        tolerance: {2, 64}
      },
      %{
        id: "crop_offset_dpr_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=300,200/anchor=right/anchor-offset=20,0/dpr=2",
        imgproxy: "c:300:200:ea:20:0/dpr:2",
        tolerance: {2, 64}
      },
      # P4: #233 square sign-bucket × #182 display-frame classification. rt:auto buckets
      # fill-vs-fit by sign(W−H) (square in the landscape bucket), classified on
      # DISPLAY-frame source dims. exif_6 is storage 400×300 (landscape bucket → fill)
      # but display 300×400 (portrait bucket → fit) against a square target; the two
      # frames pick OPPOSITE branches, so this pins that ImagePipe classifies on display.
      %{
        id: "exif_auto_square_marker",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=300/h=300/fit=auto",
        imgproxy: "rs:auto:300:300",
        tolerance: {2, 64}
      },
      # P5: odd surplus × non-center anchor (× dpr). cover_odd_gap_center_marker pins
      # ShrinkToEven(outer−inner+1,2) for the SYMMETRIC center case — the one case where
      # the rounding sign is invisible. An odd gap against a CORNER anchor is where the
      # sign actually bites: marker 4:3 into 301×200 cover-scales to ~301×226 (odd
      # vertical surplus), soea anchors the result-crop to the bottom-right. The bake
      # confirms the rounding sign is correct (a 1px origin error would shift every
      # sharp marker edge to maxΔ≈255 across thousands of bytes); the residual is the
      # marker edge-AA seam: maxΔ=18, 201 band-bytes over Δ2, 0 over Δ32. Strict Δ2,
      # budget widened just above the seam (the marker convention).
      %{
        id: "cover_odd_gap_corner_marker",
        kind: :png,
        source: "marker.png",
        native: "w=301/h=200/fit=cover/anchor=bottom-right",
        imgproxy: "rs:fill:301:200/g:soea",
        tolerance: {2, 256}
      },
      # The dpr variant doubles to 602×400; the cover upscale-under-dpr makes the skew
      # diffuse and higher-amplitude (maxΔ=43, 99 band-bytes over Δ32) rather than a
      # single thin seam — the heavy-skew profile, so the threshold is set just above
      # the measured maxΔ with a tight budget (the trim_resize
      # convention). A 1px corner-origin shift still misaligns the marker edges to
      # maxΔ≈255 over thousands of bytes, blowing Δ48/budget-64.
      %{
        id: "cover_odd_gap_corner_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=301/h=200/fit=cover/dpr=2/anchor=bottom-right",
        imgproxy: "rs:fill:301:200/g:soea/dpr:2",
        tolerance: {48, 64}
      },
      # P6: trim × EXIF × resize × gravity — the full storage→display frame handoff in a
      # single request (also the suite's deepest pipeline chain): trim, then scale and
      # cover-crop gravity, all in the displayed frame of an EXIF-5 source, with a real
      # resize between trim and the crop.
      %{
        id: "trim_exif_cover_crop",
        kind: :png,
        source: "exif_5.jpg",
        native: "trim=auto/w=200/h=150/fit=cover/anchor=top",
        imgproxy: "t:10/rs:fill:200:150/g:no",
        tolerance: {2, 64}
      },
      # B2/B3: the enlarge-off DprScale compensation branch (prepare.go calcScale,
      # `!Enlarge() && minShrink<1`). small (120×90) is smaller than the 400×400 box, so
      # with enlarge off (default) and dpr:2 the `DprScale /= minShrink` compensation
      # fires — UNLESS extend is enabled, which prepare.go explicitly skips
      # (`!po.ExtendEnabled()`). B2 isolates the compensation; B3 is the same request
      # with ex:1 so the compensation is skipped. Crossing the pair pins that ImagePipe
      # replicates the extend-skips-compensation special case.
      %{
        id: "enlarge_off_dpr_comp_small",
        kind: :png,
        source: "small.png",
        native: "w=400/h=400/fit=contain/dpr=2",
        imgproxy: "rs:fit:400:400/dpr:2",
        tolerance: {2, 64}
      },
      %{
        id: "enlarge_off_dpr_extend_small",
        kind: :png,
        source: "small.png",
        native: "w=400/h=400/fit=contain/dpr=2/extend",
        imgproxy: "rs:fit:400:400/ex:1/dpr:2",
        tolerance: {2, 64}
      },
      # B5: zoom feeding the COVER result-crop box. zoom folds into the single scale, but
      # whether it also scales the result-crop target (the #236-adjacent zoom×target box
      # interaction) is untested — zoom is only baked without a cover result-crop. Dims
      # agree at 450×300, so the zoom does feed the result-crop box correctly; the
      # residual is the 1.5× upscale resampling skew on sharp marker edges (maxΔ=40, 0
      # over Δ48). Threshold just above the skew ceiling with a tight budget.
      %{
        id: "zoom_cover_resultcrop_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/zoom=1.5",
        imgproxy: "rs:fill:300:200/z:1.5",
        tolerance: {48, 64}
      },
      # B6: extend absolute offset that OVER-clamps under dpr. small (120×90) inside the
      # 200×150 box; east offset 200 × dpr 2 = 400 pushes the image far past the canvas
      # edge, so calcPosition clamps it to the boundary (#200, allowOverflow=false) —
      # crossing the clamp with dpr offset-scaling. The existing extend offset cases stay
      # within the canvas (no clamp) or clamp without dpr.
      %{
        id: "extend_offset_clamp_dpr_small",
        kind: :png,
        source: "small.png",
        native: "w=200/h=150/fit=contain/dpr=2/extend/extend-at=right/extend-offset=200,0",
        imgproxy: "rs:fit:200:150/ex:1:ea:200:0/dpr:2",
        tolerance: {2, 64}
      },
      # B7: trim equal_hor/equal_ver symmetrization (`trim:%th:%color:%eh:%ev`). The
      # symmetrize-opposite-margins-to-the-smaller-inset branch extends each opposite-
      # margin pair to its smaller inset, so it is a no-op on the centered `border` (equal
      # margins, diff==0) — it must run on `border_asym` (off-center rect: left=100/right=
      # 200, top=60/bot=140) where plain trim → 1300×1000 but symmetrization → 1400×1080
      # reaching into the white border. The asymmetric crop is the discriminator.
      %{
        id: "trim_equal_hv_border",
        kind: :png,
        source: "border_asym.png",
        native: "trim=auto/trim-symmetry=hv",
        imgproxy: "t:10::1:1",
        tolerance: {2, 64}
      },
      # B8: symmetrization × EXIF storage-axis transpose. #182 notes equal_hor/equal_ver
      # symmetrize the STORAGE axes, which transpose vs display under EXIF 5–8. exif_5
      # (transpose) with equal_hor crosses the symmetrization branch with the frame
      # transpose — two minority branches at once.
      %{
        id: "trim_equal_h_exif5",
        kind: :png,
        source: "exif_5.jpg",
        native: "trim=auto/trim-symmetry=h",
        imgproxy: "t:10::1",
        tolerance: {2, 64}
      },
      # C2: absolute offset on a CORNER anchor of the cover result-crop. Offsets are
      # baked on cardinal/edge anchors (south, east) but never on a corner — calcPosition
      # composes both axes of the offset against the corner placement.
      %{
        id: "cover_corner_offset_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=cover/anchor=bottom-right/anchor-offset=10,10",
        imgproxy: "rs:fill:300:200/g:soea:10:10",
        tolerance: {2, 64}
      },
      # C3: focal fraction at the 0/1 boundary. fp:1:0 anchors the focus point at the
      # image's right-top edge; checks the focus-window clamp at the extreme fraction
      # (interior fp is baked, the edge is not).
      %{
        id: "crop_focal_edge_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=200,200/focus=1,0",
        imgproxy: "c:200:200:fp:1:0",
        tolerance: {2, 64}
      },
      %{
        id: "lossy_webp",
        kind: :lossy,
        source: "high_freq.webp",
        native: "w=240/h=180/fit=cover/format=webp",
        imgproxy: "rs:fill:240:180/f:webp",
        tolerance: {2, 64}
      },
      %{
        id: "lossy_jpeg_q40",
        kind: :lossy,
        source: "high_freq.jpg",
        native: "w=240/h=180/fit=cover/q=40/format=jpeg",
        imgproxy: "rs:fill:240:180/q:40/f:jpg",
        tolerance: {2, 64}
      },
      %{
        id: "lossy_avif",
        kind: :lossy,
        source: "high_freq.jpg",
        native: "w=240/h=180/fit=cover/format=avif",
        imgproxy: "rs:fill:240:180/f:avif",
        tolerance: {2, 64}
      },
      %{
        id: "exif_2_cover",
        kind: :png,
        source: "exif_2.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_2_crop_no",
        kind: :png,
        source: "exif_placement_2.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_3_cover",
        kind: :png,
        source: "exif_3.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_3_crop_no",
        kind: :png,
        source: "exif_placement_3.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_4_cover",
        kind: :png,
        source: "exif_4.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_4_crop_no",
        kind: :png,
        source: "exif_placement_4.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_5_cover",
        kind: :png,
        source: "exif_5.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_5_crop_no",
        kind: :png,
        source: "exif_placement_5.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_7_cover",
        kind: :png,
        source: "exif_7.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_7_crop_no",
        kind: :png,
        source: "exif_placement_7.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_8_cover",
        kind: :png,
        source: "exif_8.jpg",
        native: "w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "exif_8_crop_no",
        kind: :png,
        source: "exif_placement_8.jpg",
        native: "crop=200,120/anchor=top",
        imgproxy: "c:200:120/g:no",
        tolerance: {2, 64}
      },
      %{
        id: "exif_2_extend_so",
        kind: :png,
        source: "exif_2.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {32, 64}
      },
      %{
        id: "exif_3_extend_so",
        kind: :png,
        source: "exif_3.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {32, 64}
      },
      %{
        id: "exif_4_extend_so",
        kind: :png,
        source: "exif_4.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {32, 64}
      },
      %{
        id: "exif_5_extend_so",
        kind: :png,
        source: "exif_5.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {2, 64}
      },
      %{
        id: "exif_7_extend_so",
        kind: :png,
        source: "exif_7.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {2, 64}
      },
      %{
        id: "exif_8_extend_so",
        kind: :png,
        source: "exif_8.jpg",
        native: "w=200/h=300/fit=contain/extend/extend-at=bottom",
        imgproxy: "rs:fit:200:300/ex:1:so",
        tolerance: {2, 64}
      },
      # EXIF transpose/transverse ∘ user rot:90 — the deepest #146 compose path
      # (axis-swapping EXIF stacked with an axis-swapping user rotate). The user
      # rotate now flushes via the exact `vips_rot` instead of Image.rotate/2's
      # affine resampler, which had left a 1px black edge seam (#211).
      %{
        id: "exif_5_cover_rot90",
        kind: :png,
        source: "exif_5.jpg",
        native: "rotate=90/w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150/rot:90",
        tolerance: {2, 64}
      },
      %{
        id: "exif_7_cover_rot90",
        kind: :png,
        source: "exif_7.jpg",
        native: "rotate=90/w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150/rot:90",
        tolerance: {2, 64}
      },
      %{
        id: "exif_5_cover_fl",
        kind: :png,
        source: "exif_5.jpg",
        native: "flip=h/w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150/fl:1",
        tolerance: {2, 64}
      },
      %{
        id: "exif_7_cover_fl",
        kind: :png,
        source: "exif_7.jpg",
        native: "flip=h/w=200/h=150/fit=cover",
        imgproxy: "rs:fill:200:150/fl:1",
        tolerance: {2, 64}
      },
      # rt:auto branch decided on display-frame src dims. display 300×400 (portrait)
      # into a portrait target → fill; the storage frame (landscape 400×300) would
      # have mis-picked fit (a different output box).
      %{
        id: "exif_182_auto_branch",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=200/h=300/fit=auto",
        imgproxy: "rs:auto:200:300",
        tolerance: {2, 64}
      },
      # The no-enlarge effective-DPR padding cap, resolved in the display frame
      # (fitted target dims + source both ExtractGeometry-swapped). fit shrinks, so
      # the cap binds and dpr scales the padding off the display axes.
      %{
        id: "exif_182_auto_pad_dpr_cap",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=200/h=120/fit=contain/pad=10/dpr=2",
        imgproxy: "rs:fit:200:120/pd:10/dpr:2",
        tolerance: {2, 64}
      },
      # Asymmetric padding with NO resize: the resize-triggered flush never fires,
      # so the padding op itself must flush first and land pt/pr/pb/pl on display
      # sides. pd:T:R:B:L all distinct.
      %{
        id: "exif_182_padding_no_resize",
        kind: :png,
        source: "exif_6.jpg",
        native: "pad=10,4,2,8",
        imgproxy: "pd:10:4:2:8",
        tolerance: {2, 64}
      },
      # Pixelate block grid aligns to the display edges (size 7 divides neither
      # 300 nor 400, so partial edge blocks are placed by frame). The 300×400
      # output confirms the display frame; a storage-frame grid would diverge
      # grossly (every block edge at near-full contrast). With the box-mean
      # pixelate (#238) the block average matches imgproxy's vips_shrink exactly,
      # including across exif_6's sharp blue/gold quadrant edge, so the output is
      # byte-identical (maxΔ=0) — the former Δ23 residual was the Lanczos overshoot
      # at that mid-block edge, not block-average skew. Default Δ2/64; a 1px grid
      # shift would not fit.
      %{
        id: "exif_182_pixelate",
        kind: :png,
        source: "exif_6.jpg",
        native: "pixelate=7",
        imgproxy: "pix:7",
        tolerance: {2, 64}
      },
      # Coverage gaps: watermark. The asset is alpha.png on both sides; placement over
      # the placement grid makes a 1px shift fail across every cell edge.
      %{
        id: "wm_center_scaled",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-scale=0.25",
        imgproxy: "rs:fit:400:300/wm:1:ce:0:0:0.25",
        tolerance: {2, 64}
      },
      %{
        id: "wm_corner_offset",
        kind: :png,
        source: "placement.png",
        native:
          "w=400/h=300/fit=contain/wm=mark/wm-at=bottom-right/wm-offset=20,10/wm-scale=0.25",
        imgproxy: "rs:fit:400:300/wm:1:soea:20:10:0.25",
        tolerance: {2, 64}
      },
      %{
        id: "wm_opacity_top_left",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-opacity=0.5/wm-at=top-left/wm-scale=0.25",
        imgproxy: "rs:fit:400:300/wm:0.5:nowe:0:0:0.25",
        tolerance: {2, 64}
      },
      # Natural asset size: 256×256 inside a 400×300 frame.
      %{
        id: "wm_natural_size",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-at=top",
        imgproxy: "rs:fit:400:300/wm:1:no",
        tolerance: {2, 64}
      },
      # Offsets below 1 are relative in imgproxy; 10pct of the frame natively.
      %{
        id: "wm_relative_offset",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-at=left/wm-offset=10pct,0/wm-scale=0.2",
        imgproxy: "rs:fit:400:300/wm:1:we:0.1:0:0.2",
        tolerance: {2, 64}
      },
      %{
        id: "wm_tile",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-tile/wm-scale=0.1",
        imgproxy: "rs:fit:400:300/wm:1:re:0:0:0.1",
        tolerance: {2, 64}
      },
      # Pixel offsets scale with DPR. (At natural size imgproxy ignores DPR while
      # ImagePipe scales the asset with it, so this case uses wm-scale.)
      %{
        id: "wm_dpr_scaled",
        kind: :png,
        source: "marker.png",
        native:
          "w=200/h=150/fit=contain/dpr=2/wm=mark/wm-at=bottom-right/wm-offset=10,10/wm-scale=0.25",
        imgproxy: "rs:fit:200:150/dpr:2/wm:1:soea:10:10:0.25",
        tolerance: {2, 64}
      },
      # The watermark addresses the extended canvas, not just the image.
      %{
        id: "wm_on_extended_canvas",
        kind: :png,
        source: "small.png",
        native: "w=400/h=300/fit=contain/extend/wm=mark/wm-at=bottom-right/wm-scale=0.25",
        imgproxy: "rs:fit:400:300/ex:1/wm:1:soea:0:0:0.25",
        tolerance: {2, 64}
      },
      # The watermark is the last stage, so its frame includes padding.
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 28); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "wm_on_padding",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=200/fit=contain/pad=20/wm=mark/wm-at=top-left/wm-scale=0.2",
        imgproxy: "rs:fit:300:200/pd:20/wm:1:nowe:0:0:0.2",
        tolerance: {32, 64}
      },
      # A transparent frame gains coverage where the asset is opaque.
      %{
        id: "wm_on_alpha_frame",
        kind: :png,
        source: "alpha.png",
        native: "w=200/h=200/fit=contain/wm=mark/wm-opacity=0.7/wm-scale=0.5",
        imgproxy: "rs:fit:200:200/wm:0.7:ce:0:0:0.5",
        tolerance: {2, 64}
      },
      # Placement in the displayed frame of an EXIF-6 source.
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 18); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "wm_on_exif_frame",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "w=200/h=200/fit=contain/wm=mark/wm-at=bottom-right/wm-scale=0.3",
        imgproxy: "rs:fit:200:200/wm:1:soea:0:0:0.3",
        tolerance: {20, 64}
      },
      # Coverage gaps: fractional DPR. Every older DPR case uses 2; rounding at 1.5
      # and 1.25 takes different paths.
      %{
        id: "dpr15_fit_marker",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=contain/dpr=1.5",
        imgproxy: "rs:fit:200:150/dpr:1.5",
        tolerance: {2, 64}
      },
      %{
        id: "dpr15_cover_offset_marker",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=cover/anchor=bottom-right/anchor-offset=10,10/dpr=1.5",
        imgproxy: "rs:fill:200:150/g:soea:10:10/dpr:1.5",
        tolerance: {2, 64}
      },
      %{
        id: "dpr15_extend_pad_marker",
        kind: :png,
        source: "marker.png",
        native:
          "w=300/h=200/fit=contain/extend/extend-at=bottom-right/extend-offset=10,10/pad=5/dpr=1.5",
        imgproxy: "rs:fit:300:200/ex:1:soea:10:10/pd:5/dpr:1.5",
        tolerance: {2, 64}
      },
      # Source-crop offsets are physical pixels, unaffected by DPR.
      %{
        id: "dpr15_crop_offset_placement",
        kind: :png,
        source: "placement.png",
        native: "crop=300,200/anchor=right/anchor-offset=20,0/dpr=1.5",
        imgproxy: "c:300:200:ea:20:0/dpr:1.5",
        tolerance: {2, 64}
      },
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 28); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "dpr125_cover_odd_marker",
        kind: :png,
        source: "marker.png",
        native: "w=201/h=151/fit=cover/dpr=1.25",
        imgproxy: "rs:fill:201:151/dpr:1.25",
        tolerance: {32, 64}
      },
      # Coverage gaps: alpha through effects, rotation, cover crop and padding — the
      # premultiply paths.
      %{
        id: "alpha_blur",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/blur=3",
        imgproxy: "rs:fit:128:128/bl:3",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_sharpen",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/sharpen=2",
        imgproxy: "rs:fit:128:128/sh:2",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_pixelate",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/pixelate=8",
        imgproxy: "rs:fit:128:128/pix:8",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_rotate90",
        kind: :png,
        source: "alpha.png",
        native: "rotate=90/w=128/h=128/fit=contain",
        imgproxy: "rot:90/rs:fit:128:128",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_flip_h",
        kind: :png,
        source: "alpha.png",
        native: "flip=h/w=128/h=128/fit=contain",
        imgproxy: "fl:1/rs:fit:128:128",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_cover_crop",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=64/fit=cover/anchor=top",
        imgproxy: "rs:fill:128:64/g:no",
        tolerance: {2, 64}
      },
      # Padding without a background stays transparent.
      %{
        id: "alpha_pad_transparent",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/pad=10",
        imgproxy: "rs:fit:128:128/pd:10",
        tolerance: {2, 64}
      },
      # Coverage gaps: smart crop beyond one inline crop.
      %{
        id: "cover_smart_marker",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=300/fit=cover/anchor=smart",
        imgproxy: "rs:fill:300:300/g:sm",
        tolerance: {2, 64}
      },
      # Attention scoring must run in the displayed frame. Same window as imgproxy
      # (best-fit offset 0,0); the threshold covers resampling skew up to maxΔ 23.
      %{
        id: "exif_cover_smart",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "w=200/h=150/fit=cover/anchor=smart",
        imgproxy: "rs:fill:200:150/g:sm",
        tolerance: {24, 64}
      },
      # Coverage gaps: EXIF auto-orientation off (`ar:0`), a separate path through the
      # orientation flush.
      %{
        id: "orient_none_crop",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "orient=none/crop=200,120/anchor=top",
        imgproxy: "ar:0/c:200:120:no",
        tolerance: {2, 64}
      },
      %{
        id: "orient_none_cover",
        kind: :png,
        source: "exif_5.jpg",
        native: "orient=none/w=200/h=150/fit=cover",
        imgproxy: "ar:0/rs:fill:200:150",
        tolerance: {2, 64}
      },
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 16); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "orient_none_rotate",
        kind: :png,
        source: "exif_6.jpg",
        native: "orient=none/rotate=90/w=200/h=200/fit=contain",
        imgproxy: "ar:0/rot:90/rs:fit:200:200",
        tolerance: {20, 64}
      },
      # Coverage gaps: rotate 270, flip on both axes, and compositions that cancel out.
      %{
        id: "rot270_crop_placement",
        kind: :png,
        source: "placement.png",
        native: "rotate=270/crop=200,120/anchor=top",
        imgproxy: "rot:270/c:200:120:no",
        tolerance: {2, 64}
      },
      %{
        id: "flip_hv_placement",
        kind: :png,
        source: "placement.png",
        native: "flip=hv/w=400/h=300/fit=contain",
        imgproxy: "fl:1:1/rs:fit:400:300",
        tolerance: {2, 64}
      },
      # Rotating 180° and flipping both axes nets to identity.
      %{
        id: "rot180_flip_hv_identity",
        kind: :png,
        source: "placement.png",
        native: "rotate=180/flip=hv/w=400/h=300/fit=contain",
        imgproxy: "rot:180/fl:1:1/rs:fit:400:300",
        tolerance: {2, 64}
      },
      # EXIF 3 composed with rotate 180 nets to identity.
      %{
        id: "exif3_rot180_identity",
        kind: :png,
        source: "exif_placement_3.jpg",
        native: "rotate=180/w=200/h=150/fit=contain",
        imgproxy: "rot:180/rs:fit:200:150",
        tolerance: {2, 64}
      },
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 18); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "exif8_rot90_flip",
        kind: :png,
        source: "exif_placement_8.jpg",
        native: "rotate=90/flip=h/w=200/h=200/fit=contain",
        imgproxy: "rot:90/fl:1/rs:fit:200:200",
        tolerance: {20, 64}
      },
      # Coverage gaps: trim followed by other geometry.
      # Percentages resolve against the trimmed frame.
      %{
        id: "trim_then_pct_crop",
        kind: :png,
        source: "border.png",
        native: "trim=auto/crop=50pct,50pct",
        imgproxy: "t:10/c:0.5:0.5",
        tolerance: {2, 64}
      },
      %{
        id: "trim_then_extend",
        kind: :png,
        source: "border.png",
        native: "trim=auto/w=400/h=400/fit=contain/extend",
        imgproxy: "t:10/rs:fit:400:400/ex:1",
        tolerance: {2, 64}
      },
      # Coverage gaps: smaller combinations.
      %{
        id: "cover_enlarge_small",
        kind: :png,
        source: "small.png",
        native: "w=300/h=300/fit=cover/enlarge",
        imgproxy: "rs:fill:300:300:1",
        tolerance: {2, 64}
      },
      # extend-ratio on a rotated display frame.
      # Resampling skew without any shift (best-fit offset 0,0, maxΔ 16); the
      # threshold sits just above the measured maximum. A 1px shift fails far past it.
      %{
        id: "exif_extend_ratio",
        kind: :png,
        source: "exif_6.jpg",
        native: "w=300/h=200/fit=contain/extend-ratio",
        imgproxy: "rs:fit:300:200/exar:1",
        tolerance: {20, 64}
      },
      %{
        id: "zoom_dpr_marker",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=contain/zoom=1.5/dpr=2",
        imgproxy: "rs:fit:200:150/z:1.5/dpr:2",
        tolerance: {2, 64}
      },
      # Coverage gaps: CMYK, 16-bit and WebP sources beyond a plain resize.
      %{
        id: "cmyk_crop_blur",
        kind: :png,
        source: "cmyk.jpg",
        native: "crop=60,60/anchor=top/blur=2",
        imgproxy: "c:60:60:no/bl:2",
        tolerance: {2, 64}
      },
      %{
        id: "rgb16_rotate_crop",
        kind: :png,
        source: "rgb16.png",
        native: "rotate=90/crop=200,200",
        imgproxy: "rot:90/c:200:200",
        tolerance: {2, 64}
      },
      %{
        id: "rgba16_blur",
        kind: :png,
        source: "rgba16.png",
        native: "w=128/h=128/fit=contain/blur=2",
        imgproxy: "rs:fit:128:128/bl:2",
        tolerance: {2, 64}
      },
      %{
        id: "webp_cover_offset",
        kind: :png,
        source: "high_freq.webp",
        native: "w=200/h=150/fit=cover/anchor=top-right/anchor-offset=10,10",
        imgproxy: "rs:fill:200:150/g:noea:10:10",
        tolerance: {2, 64}
      },
      # Edge cases: 1-band grayscale (gray.png). imgproxy may return these promoted
      # to sRGB; the test compares in sRGB when it does.
      %{
        id: "gray_fit",
        kind: :png,
        source: "gray.png",
        native: "w=200/h=150/fit=contain",
        imgproxy: "rs:fit:200:150",
        tolerance: {2, 64}
      },
      # A neutral background keeps its gray value; a colour background or a colour
      # watermark promotes the gray image to sRGB, as imgproxy does.
      %{
        id: "gray_pad_bg",
        kind: :png,
        source: "gray.png",
        native: "w=200/h=150/fit=contain/pad=10/bg=808080",
        imgproxy: "rs:fit:200:150/pd:10/bg:808080",
        tolerance: {2, 64}
      },
      %{
        id: "gray_extend_bg",
        kind: :png,
        source: "gray.png",
        native: "w=300/h=300/fit=contain/extend/bg=ff0000",
        imgproxy: "rs:fit:300:300/ex:1/bg:ff0000",
        tolerance: {2, 64}
      },
      %{
        id: "gray_watermark",
        kind: :png,
        source: "gray.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-at=bottom-right/wm-scale=0.25",
        imgproxy: "rs:fit:400:300/wm:1:soea:0:0:0.25",
        tolerance: {2, 64}
      },
      %{
        id: "gray_blur_pixelate",
        kind: :png,
        source: "gray.png",
        native: "w=200/h=150/fit=contain/blur=2/pixelate=4",
        imgproxy: "rs:fit:200:150/bl:2/pix:4",
        tolerance: {2, 64},
        structure_differs: %{
          bands:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values",
          interpretation:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values"
        }
      },
      # Edge cases: 2-band grayscale with alpha (gray_alpha.png).
      # Resampling skew, no shift; threshold just above the measured maxΔ 11 (premultiplied).
      %{
        id: "gray_alpha_fit",
        kind: :png,
        source: "gray_alpha.png",
        native: "w=200/h=150/fit=contain",
        imgproxy: "rs:fit:200:150",
        tolerance: {12, 64}
      },
      # Resampling skew, no shift; threshold just above the measured maxΔ 11.
      %{
        id: "gray_alpha_flatten",
        kind: :png,
        source: "gray_alpha.png",
        native: "w=200/h=150/fit=contain/bg=ffffff",
        imgproxy: "rs:fit:200:150/bg:ffffff",
        tolerance: {12, 64}
      },
      # Resampling skew, no shift; threshold just above the measured maxΔ 7 (premultiplied).
      %{
        id: "gray_alpha_extend",
        kind: :png,
        source: "gray_alpha.png",
        native: "w=300/h=300/fit=contain/extend",
        imgproxy: "rs:fit:300:300/ex:1",
        tolerance: {8, 64}
      },
      %{
        id: "gray_alpha_blur",
        kind: :png,
        source: "gray_alpha.png",
        native: "w=200/h=150/fit=contain/blur=3",
        imgproxy: "rs:fit:200:150/bl:3",
        tolerance: {2, 64},
        structure_differs: %{
          bands:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values",
          interpretation:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values"
        }
      },
      # Resampling skew, no shift; threshold just above the measured maxΔ 11 (premultiplied).
      %{
        id: "gray_alpha_rotate",
        kind: :png,
        source: "gray_alpha.png",
        native: "rotate=90/w=150/h=200/fit=contain",
        imgproxy: "rot:90/rs:fit:150:200",
        tolerance: {12, 64}
      },
      # Trim from a transparent top-left corner on a 2-band image.
      %{
        id: "gray_alpha_trim",
        kind: :png,
        source: "gray_alpha.png",
        native: "trim=auto",
        imgproxy: "t:10",
        tolerance: {2, 64}
      },
      # Edge cases: palette and 1-bit PNG sources.
      # Resampling skew, no shift; threshold just above the measured maxΔ 8.
      %{
        id: "palette_fit",
        kind: :png,
        source: "palette.png",
        native: "w=200/h=150/fit=contain",
        imgproxy: "rs:fit:200:150",
        tolerance: {10, 64}
      },
      %{
        id: "palette_crop",
        kind: :png,
        source: "palette.png",
        native: "crop=120,90/anchor=bottom-right",
        imgproxy: "c:120:90:soea",
        tolerance: {2, 64}
      },
      # Resampling skew, no shift; threshold just above the measured maxΔ 18.
      %{
        id: "palette_extend_bg",
        kind: :png,
        source: "palette.png",
        native: "w=300/h=300/fit=contain/extend/bg=00ff00",
        imgproxy: "rs:fit:300:300/ex:1/bg:00ff00",
        tolerance: {20, 64}
      },
      %{
        id: "bitonal_fit",
        kind: :png,
        source: "bitonal.png",
        native: "w=200/h=150/fit=contain",
        imgproxy: "rs:fit:200:150",
        tolerance: {2, 64}
      },
      %{
        id: "bitonal_pixelate",
        kind: :png,
        source: "bitonal.png",
        native: "pixelate=10",
        imgproxy: "pix:10",
        tolerance: {2, 64},
        structure_differs: %{
          bands:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values",
          interpretation:
            "ImagePipe keeps the gray result gray; imgproxy promotes it to sRGB with the same values"
        }
      },
      %{
        id: "bitonal_crop",
        kind: :png,
        source: "bitonal.png",
        native: "crop=100,100",
        imgproxy: "c:100:100:ce",
        tolerance: {2, 64}
      },
      # Edge cases: a 1600×1200 EXIF-6 source, where shrink-on-load and pending
      # orientation meet.
      # Resampling skew, no shift; threshold just above the measured maxΔ 28, from shrink-on-load.
      %{
        id: "exif_large_cover_offset",
        kind: :png,
        source: "exif_large_6.jpg",
        native: "w=200/h=150/fit=cover/anchor=bottom-right/anchor-offset=10,10",
        imgproxy: "rs:fill:200:150/g:soea:10:10",
        tolerance: {32, 64}
      },
      %{
        id: "exif_large_fit",
        kind: :png,
        source: "exif_large_6.jpg",
        native: "w=300/h=300/fit=contain",
        imgproxy: "rs:fit:300:300",
        tolerance: {2, 64}
      },
      # Resampling skew, no shift; threshold just above the measured maxΔ 32, from shrink-on-load.
      %{
        id: "exif_large_crop_fit",
        kind: :png,
        source: "exif_large_6.jpg",
        native: "crop=800,600/anchor=top-left/w=200/h=200/fit=contain",
        imgproxy: "c:800:600:nowe/rs:fit:200:200",
        tolerance: {36, 64}
      },
      %{
        id: "exif_large_cover_focus",
        kind: :png,
        source: "exif_large_6.jpg",
        native: "w=300/h=200/fit=cover/focus=0.2,0.8",
        imgproxy: "rs:fill:300:200/g:fp:0.2:0.8",
        tolerance: {2, 64}
      },
      %{
        id: "exif_large_cover_dpr",
        kind: :png,
        source: "exif_large_6.jpg",
        native: "w=150/h=100/fit=cover/anchor=top/dpr=2",
        imgproxy: "rs:fill:150:100/g:no/dpr:2",
        tolerance: {2, 64}
      },
      # Edge cases: a 2000×8 strip, where the short axis rounds towards zero.
      %{
        id: "strip_fit_width",
        kind: :png,
        source: "strip.png",
        native: "w=100",
        imgproxy: "rs:fit:100:0",
        tolerance: {2, 64}
      },
      %{
        id: "strip_fit_box",
        kind: :png,
        source: "strip.png",
        native: "w=400/h=400/fit=contain",
        imgproxy: "rs:fit:400:400",
        tolerance: {2, 64}
      },
      %{
        id: "strip_extend",
        kind: :png,
        source: "strip.png",
        native: "w=200/h=50/fit=contain/extend",
        imgproxy: "rs:fit:200:50/ex:1",
        tolerance: {2, 64}
      },
      # Edge cases: trim with nothing but background, and trim on transparency.
      # Trim finds no content.
      %{
        id: "uniform_trim",
        kind: :png,
        source: "uniform.png",
        native: "trim=auto",
        imgproxy: "t:10",
        tolerance: {2, 64}
      },
      %{
        id: "uniform_trim_resize",
        kind: :png,
        source: "uniform.png",
        native: "trim=auto/w=100/h=100/fit=contain",
        imgproxy: "t:10/rs:fit:100:100",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_border_trim",
        kind: :png,
        source: "alpha_border.png",
        native: "trim=auto",
        imgproxy: "t:10",
        tolerance: {2, 64}
      },
      # Padding after trim stays transparent.
      %{
        id: "alpha_border_trim_pad",
        kind: :png,
        source: "alpha_border.png",
        native: "trim=auto/pad=10",
        imgproxy: "t:10/pd:10",
        tolerance: {2, 64}
      },
      %{
        id: "alpha_border_trim_symmetric",
        kind: :png,
        source: "alpha_border.png",
        native: "trim=auto/trim-symmetry=hv",
        imgproxy: "t:10::1:1",
        tolerance: {2, 64}
      },
      # Edge cases: degenerate sizes.
      # A block larger than the image.
      %{
        id: "pixelate_larger_than_image",
        kind: :png,
        source: "small.png",
        native: "pixelate=500",
        imgproxy: "pix:500",
        tolerance: {2, 64}
      },
      # Odd block on a transverse EXIF frame (the mirror-padding path).
      %{
        id: "pixelate_odd_exif7",
        kind: :png,
        source: "exif_placement_7.jpg",
        native: "pixelate=7",
        imgproxy: "pix:7",
        tolerance: {2, 64}
      },
      %{
        id: "pixelate_odd_dims",
        kind: :png,
        source: "placement.png",
        native: "w=201/h=151/fit=contain/pixelate=8",
        imgproxy: "rs:fit:201:151/pix:8",
        tolerance: {2, 64}
      },
      %{
        id: "crop_larger_than_image",
        kind: :png,
        source: "small.png",
        native: "crop=2000,2000",
        imgproxy: "c:2000:2000",
        tolerance: {2, 64}
      },
      # An offset pushing the crop outside the image clamps it inside.
      %{
        id: "crop_offset_out_of_bounds",
        kind: :png,
        source: "small.png",
        native: "crop=100,80/anchor=top-left/anchor-offset=500,500",
        imgproxy: "c:100:80:nowe:500:500",
        tolerance: {2, 64}
      },
      # Edge cases: options that change nothing.
      %{
        id: "extend_ratio_already_matching",
        kind: :png,
        source: "marker.png",
        native: "w=400/h=300/fit=contain/extend-ratio",
        imgproxy: "rs:fit:400:300/exar:1",
        tolerance: {2, 64}
      },
      %{
        id: "bg_on_opaque",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=contain/bg=ff0000",
        imgproxy: "rs:fit:200:150/bg:ff0000",
        tolerance: {2, 64}
      },
      %{
        id: "extend_canvas_matching",
        kind: :png,
        source: "marker.png",
        native: "w=400/h=300/fit=contain/extend",
        imgproxy: "rs:fit:400:300/ex:1",
        tolerance: {2, 64}
      }
    ]
  end
end

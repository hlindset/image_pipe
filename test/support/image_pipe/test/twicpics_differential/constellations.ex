defmodule ImagePipe.Test.TwicpicsDifferential.Constellations do
  @moduledoc """
  Authored TwicPics differential cases. Imported by BOTH the bake task and the
  conformance test so the two cannot drift. Each entry is authored intent
  (`id`, `source`, `chain`, `verdict`, `group`, optional `tol`/`triage`);
  provenance (dims/bands/oracle signature/committed fixture PNG) lives in the
  generated manifest, joined by `:id`. Every output is pinned `output=png`,
  no path-default manipulation. `dpr` is omitted: live TwicPics default DPR is
  1× (verified byte-identical with and without `dpr=1`), and ImagePipe's parser
  doesn't implement dpr.

  The gate is a per-band pixel comparison of the live ImagePipe render against the
  committed TwicPics (libvips) fixture, with a per-case tolerance budget — TwicPics
  renders with libvips, so most cases are pixel-identical and the rest differ only
  by resampling skew. See `default_tol/0` and the per-case `:tol`/`:triage`.
  """
  use Boundary, top_level?: true, deps: []

  # Pixel tolerance default lives in `default_tol/0`; Constellations stays deps: [].
  @doc "Default per-band pixel tolerance: Δ2 threshold, 64 band-byte budget."
  def default_tol, do: %{threshold: 2, budget: 64}

  @source_files %{grid_4x4: "grid_4x4.png"}
  @suffix "output=png"

  @doc "Map of `source` atom -> committed source filename."
  def source_files, do: @source_files
  @doc "Committed source filename for a constellation."
  def source_file(%{source: source}), do: Map.fetch!(@source_files, source)
  @doc "The pinned request suffix (determinism pins)."
  def suffix, do: @suffix

  @doc "The TwicPics request path for a constellation (shared by bake + test)."
  def twicpics_path(%{source: source, chain: chain}),
    do: "/#{Map.fetch!(@source_files, source)}?twic=v1/#{chain}/#{@suffix}"

  @doc """
  The authored constellation list (full issue initial scope).

  Discrimination note: the source is square (400×400), so a SYMMETRIC consumer
  (`cover=NxN`, `contain=NxN`) on it is a pure uniform downscale — no crop, no
  letterbox — so focus cannot move anything and the output is independent of the
  anchor. To actually exercise focus placement, crop region, and fit, the
  focus/crop cases use ASYMMETRIC consumers (`cover=300x100`, `cover=100x300`,
  ratio crops) or a small guided `crop` (which, like the #321 probe, reads the
  carried point). Negative-focus *rejection* (TwicPics 404s; ImagePipe 400s) has
  no image to compare, so it is out of this differential suite — it lives in the
  `Units` parser unit tests; see the suite README.
  """
  def all do
    [
      # --- focus anchors steer an ASYMMETRIC cover (the cropped axis reveals the point) ---
      c("focus_center_cover_wide", "focus=center/cover=300x100", :focus),
      c("focus_topleft_cover_wide", "focus=top-left/cover=300x100", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      c("focus_bottomright_cover_wide", "focus=bottom-right/cover=300x100", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      c("focus_left_cover_tall", "focus=left/cover=100x300", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      c("focus_right_cover_tall", "focus=right/cover=100x300", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      # --- focus pixel + relative coords (0-based), asymmetric consumer ---
      c("focus_px_origin_cover_wide", "focus=0x0/cover=300x100", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      c("focus_px_last_cover_tall", "focus=399x399/cover=100x300", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      c("focus_rel_mid_cover_wide", "focus=50px50p/cover=300x100", :focus),
      c("focus_mixed_units_cover_tall", "focus=300x50p/cover=100x300", :focus),
      # --- focus OOB clamp (confirmed live: positive past-edge clamps to the edge) ---
      c("focus_oob_clamp_cover_wide", "focus=500x500/cover=300x100", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      # `150px150p` is 150p × 150p (150% × 150%) — NOT a `px` pixel unit; both clamp to
      # the far edge (confirmed live; the parser clamps ratio>1 per #321).
      c("focus_oob_rel_clamp_cover_tall", "focus=150px150p/cover=100x300", :focus,
        tol: %{threshold: 16, budget: 64}
      ),
      # --- cover-RATIO steered by focus (the documented ratio consumer, #321) ---
      c("focus_topleft_cover_ratio", "focus=top-left/cover=16:9", :focus),
      # MONITORED DIVERGENCE (#331), same root cause as `cover_ratio_tall`: the largest
      # 2:3 area on the 400×400 source is 266.667-wide (fractional), so TwicPics
      # sub-pixel-resamples it to the rounded integer output, antialiasing the
      # cropped-axis cell edges; ImagePipe does a sharp integer crop. Placement matches
      # to sub-pixel. Accepted and permanent — stays on the default lane inside a
      # two-sided band (regresses if it grows toward a real shift, promotes if a libvips
      # update makes it match). See the `cover=W:H` "Diverges" note in the support matrix.
      c("focus_bottomright_cover_ratio", "focus=bottom-right/cover=2:3", :focus,
        verdict: :diverges,
        divergence: %{
          reason:
            "Bottom-right focus on the 2:3 cover-ratio crop. The largest matching area is fractional (266.667w), so TwicPics sub-pixel-resamples it to the integer output (cell-edge antialiasing); ImagePipe integer-crops. Placement matches to sub-pixel. Permanent — see the cover=W:H Diverges note in docs/twicpics_support_matrix.md.",
          max_delta: 24..96,
          outliers: 2_700..4_400,
          issue: 331
        }
      ),
      # --- focus carry-through: identical focus, resize before vs after → different cell ---
      # resize first (400→200): focus 50x50 in the 200-frame = source (100,100) = cell (1,1)
      c("focus_carry_then_crop", "resize=50p/focus=50x50/crop=40x40", :focus),
      # focus first in the 400-frame: source (50,50) = cell (0,0), carried through resize
      c("focus_carry_resize_then_crop", "focus=50x50/resize=50p/crop=40x40", :focus),
      # --- focus persists across MULTIPLE consumers (asymmetric cover, then crop) ---
      c("focus_multi_consumer", "focus=top-left/cover=300x100/crop=40x40", :focus),
      # --- cover: size (asymmetric = discriminating; square = dims-pin) + ratio ---
      c("cover_wide", "cover=300x100", :cover),
      c("cover_tall", "cover=100x300", :cover),
      c("cover_square_dimspin", "cover=200x200", :cover),
      # `cover=16:9` on the 400×400 source extracts a 400×225 area — an exact integer
      # crop, byte-identical to TwicPics, so it stays a live `:equal` case.
      c("cover_ratio_wide", "cover=16:9", :cover),
      # MONITORED DIVERGENCE (#331). The largest 2:3 area is 266.667-wide (fractional);
      # TwicPics sub-pixel-resamples that float area to the rounded 267-wide output,
      # antialiasing the vertical cell edges, where ImagePipe does a sharp integer crop.
      # Placement matches to sub-pixel (only the boundary lines differ) — see the
      # `cover=W:H` "Diverges" note in the support matrix. Accepted and permanent: stays
      # on the default lane inside a two-sided band rather than excluded.
      c("cover_ratio_tall", "cover=2:3", :cover,
        verdict: :diverges,
        divergence: %{
          reason:
            "Confined to the cell-boundary lines (~Δ92): the largest 2:3 area is fractional (266.667w), so TwicPics sub-pixel-resamples it to the integer output (cell-edge antialiasing); ImagePipe integer-crops. Placement matches to sub-pixel. Permanent — see the cover=W:H Diverges note in docs/twicpics_support_matrix.md.",
          max_delta: 60..160,
          outliers: 3_000..4_600,
          issue: 331
        }
      ),
      # --- contain: fits inside box, may be smaller, no pad (wide/tall discriminate) ---
      c("contain_wide", "contain=300x100", :contain),
      c("contain_tall", "contain=100x300", :contain),
      c("contain_square_dimspin", "contain=150x150", :contain),
      # --- inside: fits + letterbox to the exact box (translucent borders). Square-in-
      # square produces NO letterbox (== contain) so it can't discriminate; only the
      # asymmetric boxes letterbox and are worth baking. ---
      c("inside_wide_lr", "inside=300x100", :inside),
      c("inside_tall_tb", "inside=100x300", :inside),
      # --- crop: guided (focus) vs region@coords ---
      c("crop_guided_focus_tl", "focus=top-left/crop=120x120", :crop),
      c("crop_region_origin", "crop=160x160@40x40", :crop),
      # `crop=WxH@XxY` does NOT reset the focus to the crop centre (the official docs
      # say it does; live TwicPics disagrees — #331). The focus is CARRIED through the
      # region crop, translated + clamped into the new frame like every other geometry
      # op, so the trailing guided `crop=80x80` reads the carried point. This pair makes
      # the carry observable: identical region crop (`crop=200x200@150x150`, source
      # [150,350]), different pre-region focus → the trailing window lands on a different
      # cell boundary. A focus-reset (the prior model) would center both identically.
      c("crop_region_carry_far", "focus=300x300/crop=200x200@150x150/crop=80x80", :crop),
      c("crop_region_carry_near", "focus=150x150/crop=200x200@150x150/crop=80x80", :crop),
      # --- number: parenthesized arithmetic folds to the same render as its literal,
      # rounds bare-pixel results half away from zero, and clamps a sub-1 dimension to 1
      # (#325). Confirmed live: (300/2)x(50*2)=150x100, (100/(4/2))=50, (7/2)→4, (1/4)→1.
      # A `/` inside the parens is division, not a chain separator. ---
      c("number_fold_asymmetric", "resize=(300/2)x(50*2)", :number),
      c("number_nested_chain_safe", "resize=(100/(4/2))", :number),
      c("number_round_half_up", "resize=(7/2)", :number),
      c("number_clamp_to_one", "resize=(1/4)", :number)
    ]
  end

  defp c(id, chain, group, opts \\ []) do
    Map.merge(
      %{id: id, source: :grid_4x4, chain: chain, verdict: :equal, group: group},
      Map.new(opts)
    )
  end
end

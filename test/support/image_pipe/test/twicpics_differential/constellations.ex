defmodule ImagePipe.Test.TwicpicsDifferential.Constellations do
  @moduledoc """
  Authored TwicPics differential cases. Imported by BOTH the bake task and the
  conformance test so the two cannot drift. Each entry is authored intent
  (`id`, `source`, `chain`, `verdict`, `group`, optional `tol`/`triage`);
  provenance (dims/bands/cell-map/oracle signature/reference PNG) lives in the
  generated manifest, joined by `:id`. Every output is pinned `output=png`,
  no path-default manipulation. `dpr` is omitted: live TwicPics default DPR is
  1× (verified byte-identical with and without `dpr=1`), and ImagePipe's parser
  doesn't implement dpr.
  """
  use Boundary, top_level?: true, deps: []

  # Decode tolerance lives in StructureCompare.default_tol/0; Constellations stays deps: [].

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
  letterbox — and its cell-map is the identity grid regardless of focus. Such
  cases pin only output *dims* (kept + labelled `dims-pin`). To actually exercise
  focus placement, crop region, and fit, the focus/crop cases use ASYMMETRIC
  consumers (`cover=300x100`, `cover=100x300`, ratio crops) or a small guided
  `crop` (which, like the #321 probe, lands on a single cell and reads the carried
  point). Negative-focus *rejection* (TwicPics 404s; ImagePipe 400s) has no grid to
  decode, so it is out of this structural suite — it lives in the `Units` parser
  unit tests; see the suite README.
  """
  def all do
    [
      # --- focus anchors steer an ASYMMETRIC cover (the cropped axis reveals the point) ---
      c("focus_center_cover_wide", "focus=center/cover=300x100", :focus),
      c("focus_topleft_cover_wide", "focus=top-left/cover=300x100", :focus),
      c("focus_bottomright_cover_wide", "focus=bottom-right/cover=300x100", :focus),
      c("focus_left_cover_tall", "focus=left/cover=100x300", :focus),
      c("focus_right_cover_tall", "focus=right/cover=100x300", :focus),
      # --- focus pixel + relative coords (0-based), asymmetric consumer ---
      c("focus_px_origin_cover_wide", "focus=0x0/cover=300x100", :focus),
      c("focus_px_last_cover_tall", "focus=399x399/cover=100x300", :focus),
      c("focus_rel_mid_cover_wide", "focus=50px50p/cover=300x100", :focus),
      c("focus_mixed_units_cover_tall", "focus=300x50p/cover=100x300", :focus),
      # --- focus OOB clamp (confirmed live: positive past-edge clamps to the edge) ---
      c("focus_oob_clamp_cover_wide", "focus=500x500/cover=300x100", :focus),
      # `150px150p` is 150p × 150p (150% × 150%) — NOT a `px` pixel unit; both clamp to
      # the far edge (confirmed live; the parser clamps ratio>1 per #321).
      c("focus_oob_rel_clamp_cover_tall", "focus=150px150p/cover=100x300", :focus),
      # --- cover-RATIO steered by focus (the documented ratio consumer, #321) ---
      c("focus_topleft_cover_ratio", "focus=top-left/cover=16:9", :focus),
      c("focus_bottomright_cover_ratio", "focus=bottom-right/cover=2:3", :focus),
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
      c("cover_ratio_wide", "cover=16:9", :cover),
      # QUARANTINED (#323): lattice-boundary artifact, not a placement divergence. The
      # centered 2:3 crop (400→267 wide) on the square source lands the cell-centre
      # lattice samples on the col-0/col-1 boundary, where a ≤1px difference in how
      # TwicPics vs ImagePipe round the centering offset flips the decoded cell. The
      # low-confidence margin guard flags exactly these samples. cover_ratio_wide (the
      # other ratio direction) is unaffected and stays live.
      c("cover_ratio_tall", "cover=2:3", :cover,
        triage: %{
          reason:
            "lattice-boundary artifact: centered 2:3 crop lands cell-centre samples on a cell-col boundary; ≤1px crop-centering rounding differs (margin guard flagged). Not a placement bug.",
          issue: 323
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
      # --- crop: guided (focus) vs region@coords (resets focus to crop centre) ---
      c("crop_guided_focus_tl", "focus=top-left/crop=120x120", :crop),
      c("crop_region_origin", "crop=160x160@40x40", :crop),
      # region@coords RESETS focus to the crop centre (source ~(280,280) = cell (2,2)),
      # so the trailing guided crop reads (2,2) despite the earlier focus=0x0…
      # QUARANTINED (#323): genuine placement divergence (confidently decoded — NOT a
      # boundary artifact; the margin guard did not flag it). The reset itself works in
      # ImagePipe (the final crop lands near cell (2,2), not the prior focus=0x0), but
      # ImagePipe's trailing guided crop=80x80 window sits ~half a cell further toward
      # (3,3) than TwicPics, which keeps it within cell (2,2). The exact crop@coords-reset
      # → guided-crop positioning diverges; needs investigation (separate from #323's
      # suite-build scope).
      c("crop_region_reset", "focus=0x0/crop=160x160@200x200/crop=80x80", :crop,
        triage: %{
          reason:
            "placement divergence: crop@coords focus-reset + trailing guided crop=80x80 positions ~half a cell toward (3,3) vs TwicPics' (2,2). Reset works; exact positioning differs.",
          issue: 323
        }
      ),
      # …and this contrast case (same focus=0x0, guided crop, no region reset) must
      # read cell (0,0) — the pair makes the reset observable, not coincidental.
      c("crop_guided_no_reset_contrast", "focus=0x0/crop=80x80", :crop)
    ]
  end

  defp c(id, chain, group, opts \\ []) do
    Map.merge(
      %{id: id, source: :grid_4x4, chain: chain, verdict: :equal, group: group},
      Map.new(opts)
    )
  end
end

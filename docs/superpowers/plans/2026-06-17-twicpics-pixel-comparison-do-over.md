# TwicPics differential do-over → imgproxy-style pixel comparison

> **For agentic workers:** execute with superpowers:subagent-driven-development, fresh subagent per task, two-stage review. Steps use `- [ ]` checkboxes.

**Status:** approved by user 2026-06-17, paused for context compaction before execution. Resume by reading this file.

**Branch/PR:** `feat/twicpics-structural-differential` → [PR #330](https://github.com/hlindset/image_pipe/pull/330) (open, green, not merged). This do-over lands on the SAME branch (greenfield, unmerged — replace in place, no back-compat).

## Why (the finding)

TwicPics is **libvips-based** — see memory `project-twicpics-is-libvips`. Pixel-comparing the 30 committed fixtures + live awkward-scale probes against ImagePipe (pinned `output=png`):
- **19/30 pixel-identical** (maxΔ=0), incl. non-integer scales (`resize=173`/`237`, `contain=111x111`).
- **8/30 low-skew** maxΔ=12 (focus cover cases) — imgproxy-grade resampling skew.
- **3/30 diverge** >Δ32, all **port-level placement** bugs (not engine): `focus_bottomright_cover_ratio` Δ43 (**cell-map MISSED this** — it passes the structural gate), `cover_ratio_tall` Δ92, `crop_region_reset` Δ85.

Conclusion: the bespoke colour-grid `StructureCompare` cell-map solved a non-problem and is *less* sensitive than pixel comparison. Switch the TwicPics suite to imgproxy's pixel-comparison machinery: more reuse, stricter gate, consistent architecture.

## Goal

Re-shape the TwicPics differential suite to be "the imgproxy suite with a live-API+catbox oracle + TwicPics chains + retuned tolerances," and give it imgproxy's full filterable report. Delete the cell-map.

## Reused / Swapped / Deleted

| Reused as-is | Swapped to imgproxy's way | Deleted |
|---|---|---|
| 30 baked reference PNGs (**no network re-bake** — reuse the committed `fixtures/*.png`), catbox oracle + incremental bake, `Constellations` (chains), `SourceInventory`, the shared `Differential.{ManifestTerm, Harness, Heatmap}` | Conformance → `PixelCompare` (`dims == fixture && outliers <= tol.budget`); `Manifest` entry shape → `{authored_sha256, oracle_signature, fixture_filename, fixture_sha256, tol}` (drop `dims/bands/cells`); provenance → record `TwicPics/<ver>` + `pipe_libvips_at_gen`; the **full shared interactive report** (filters/JS/counts) | `StructureCompare` + `structure_compare_test.exs`; the structural records |

`PixelCompare` lifts into `Differential.*` (shared by both suites). The report's CSS design system + filter/toggle JS + counts + filter-bar promote into a shared `Differential.ReportUI` (or extend `ReportShell`), parametrized by filter axes (status + group vocab) + a per-card body renderer; each suite supplies only its card body.

## Tolerance calibration data (author tols from this; verify via `mix twicpics.diagnose`)

`tol = %{threshold, budget}`, imgproxy semantics. Default `%{threshold: 2, budget: 64}`.

- **19 cases: pixel-identical (maxΔ=0)** → default tol. (incl. `cover_wide`, `cover_tall`, `cover_square_dimspin`, `cover_ratio_wide`, `contain_wide/tall/square_dimspin`, `inside_wide_lr`, `inside_tall_tb`, `crop_guided_focus_tl`, `crop_region_origin`, `crop_guided_no_reset_contrast`, `focus_center_cover_wide`, `focus_topleft_cover_ratio` (note: topleft identical, bottomright diverges — gravity-dependent), `focus_rel_mid_cover_wide`, `focus_mixed_units_cover_tall`, `focus_carry_then_crop`, `focus_carry_resize_then_crop`, `focus_multi_consumer`.)
- **8 cases: skew maxΔ=12** (over Δ2: 600–900 samples; over Δ16: 0) → tol `%{threshold: 16, budget: 64}` (threshold just above measured maxΔ; over16=0 so it passes with margin). Cases: `focus_topleft_cover_wide`, `focus_bottomright_cover_wide`, `focus_left_cover_tall`, `focus_right_cover_tall`, `focus_px_origin_cover_wide`, `focus_px_last_cover_tall`, `focus_oob_clamp_cover_wide`, `focus_oob_rel_clamp_cover_tall`.
- **3 cases: diverge (quarantine `:triage`, verdict stays excluded)** — `focus_bottomright_cover_ratio` (Δ43 — **newly surfaced**, was green under cell-map; investigate cover-ratio gravity math), `cover_ratio_tall` (Δ92, already triaged), `crop_region_reset` (Δ85, already triaged). All track #323 / a placement-math follow-up.

## Tasks

- [x] **0. Zone-plate confirmation (belt-and-suspenders, network).** DONE 2026-06-18. Generated a 400×400 RGB radial-sine zone plate (highest-frequency resampling stress), uploaded to catbox, baked `resize=137/output=png` (0.3425× non-integer downscale) live, pixel-compared vs ImagePipe: **maxΔ=0, byte-identical** (over Δ2/16/32/64 all 0). Confirms libvips on high-frequency interior content, not just the flat grid's edges. Premise airtight → proceed with the do-over and delete StructureCompare.
- [ ] **1. Lift `PixelCompare` → `Differential.PixelCompare`** (shared, `deps: []`), refactor imgproxy suite to use it; imgproxy conformance (162) + `:imgproxy_report` smoke stay green.
- [ ] **2. Reshape TwicPics `Manifest`** to imgproxy-style entry shape + `validate_entry!`; provenance fields (`twicpics_version`, `pipe_libvips_at_gen`). Keep `oracle_signature`/`fresh?`/serialization.
- [ ] **3. Migrate the committed manifest** to the new shape from the existing PNGs (no network): a one-time `reauthor`-style pass that records `fixture_sha256` + authored tols per the calibration table. (The 30 PNGs are reused.)
- [ ] **4. Rewrite TwicPics conformance test** → pixel (`dims` + `PixelCompare.outliers <= tol.budget`), fixture-hash check, `:twicpics_triage` exclusion. Drop cell-map. Author the 3 quarantines + 8 skew tols.
- [ ] **5. Update `twicpics.gen_fixtures`** to record imgproxy-shape entries (fetch oracle PNG → store hash + carry authored tol). Keep incremental/catbox/prune. Verify a no-op bake is idempotent.
- [ ] **6. Rewrite `twicpics.diagnose`** → `PixelCompare.diagnose` (maxΔ histogram), like imgproxy's.
- [ ] **7. Shared interactive report.** Promote imgproxy `report_html.ex`'s `css/0` + `script/0` + filter-bar + `counts/1` + attention-sort into a shared `Differential.ReportUI`, parametrized by filter axes + per-card body. Refactor imgproxy `ReportHtml` onto it (keep `:imgproxy_report` smoke + render unit tests green). Build TwicPics report body (oracle/pipe slider + 1+ pixel heatmaps) on it → **filter/toggle/counts parity with imgproxy** (the user's ask). Add a TwicPics `:twicpics_report` smoke test.
- [ ] **8. Delete `StructureCompare` + `structure_compare_test.exs`**; remove all refs (Constellations no longer needs grid-spec wiring for the gate; SourceInventory `grid` field can stay as harmless metadata or be dropped).
- [ ] **9. Docs rewrite.** README + spec premise → libvips-based / pixel comparison like imgproxy / cell-map removed; update the 2→3 quarantine list; `docs/twicpics_support_matrix.md` note.
- [ ] **10. Full gate** (`mise run precommit`) + quarantine lane + final whole-implementation review. Update PR #330 description.

## Notes / risks

- **Don't disturb the imgproxy suite's green state** — every shared-extraction/report refactor keeps imgproxy's conformance (162) + render unit tests + `:imgproxy_report` smoke green as the regression gate.
- **`mix imgproxy.gen_report`** was just fixed (commit 3eedfd6c) to survive triaged parser-gap renders — preserve that behavior through the report refactor.
- The flat-grid source has low discriminating power for *resampling* (only edges); it's fine for *placement*. If a tighter resampling gate is wanted later, add a high-freq source. Pixel comparison + the grid is sufficient for the current placement-focused cases.
- TwicPics default processing was only characterized on PNG downscales/crops; upscale/non-PNG/quality divergences are unexplored (out of scope here; note in docs).

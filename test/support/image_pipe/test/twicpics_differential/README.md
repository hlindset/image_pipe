# TwicPics structural differential conformance — fixtures

Reference fixtures generated from the live hosted TwicPics Image API. The
comparison test (`test/image_pipe/twicpics_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no network in the hot path.

Unlike the imgproxy suite, this suite does **not** compare pixels: TwicPics is a
non-libvips engine, so per-pixel equality is not a meaningful target. Instead it
asserts **geometry/placement structure**: decoded output dims, band count, and a
decoded colour-grid cell-map. The colour-grid source encodes content identity — each
cell `(col, row)` is a distinct colour — so sampling the output at a fixed
cell-centre lattice and decoding each sample to its nearest cell yields a placement
fingerprint that survives the foreign engine's resampling. Generous colour tolerance
lives only inside the per-sample decode step (`StructureCompare`); the gate itself is
structural, not pixel.

## Bake (requires network)

After adding or editing a constellation in `constellations.ex`, run:

```shell
mise run twic:bake
```

It bakes every fixture + `manifest.exs` + `REPORT.md` against the live hosted
TwicPics API (incremental — unchanged cases are skipped with zero requests). A parse
gate validates every non-triaged constellation's chain first and aborts (listing the
offenders) before any oracle call, so a typo or unsupported chain fails fast. A
`triage`-quarantined constellation is skipped by the gate but still baked — see
*Quarantine mechanism*.

Then review the `REPORT.md` diff, run `mix twicpics.diagnose` on any failures (see
below), and commit the changed `fixtures/`, `manifest.exs`, and `REPORT.md`.

For a `tol` tweak or a verdict-only edit (no pixels change), skip the bake and
refresh the manifest's authored hashes: `mix twicpics.reauthor`.

```
mise run twic:bake                           # incremental
mix twicpics.gen_fixtures --force            # re-bake all cases
mix twicpics.gen_fixtures --only id1,id2     # re-bake specific cases
```

(`twicpics.gen_fixtures`, `twicpics.diagnose`, `twicpics.gen_report`, and
`twicpics.reauthor` auto-select `MIX_ENV=test` via `mix.exs` `preferred_envs` — no
prefix needed; the network bake goes through `mise run twic:bake`.)

## Determinism pins

Every constellation pins `output=png`. `dpr` is intentionally omitted: the live
TwicPics default DPR is already 1x — verified byte-identical output with and without
`dpr=1` — and ImagePipe's TwicPics parser does not implement `dpr`, so pinning it
would break the shared render path with no determinism gain. No path-default
manipulation.

## No libvips provenance

The cell-map gate is resampler-independent: it decodes colours, not comparing raw
pixels, so the oracle engine's resampler and ImagePipe's libvips version are
irrelevant to the gate. There is no libvips version note in the manifest.

The visual-diff report (`mix twicpics.gen_report`) shows per-case pixel heatmaps
where dims + bands match, but these are **informational only, never a gate** — engine
differences in resampling are expected and fine.

## Source inventory (keep it in sync)

Every committed source in `sources/` is catalogued in
[`source_inventory.ex`](source_inventory.ex)
(`ImagePipe.Test.TwicpicsDifferential.SourceInventory`) — its dims, bands, format,
interpretation, embedded-profile presence, how it is produced, who consumes it, and
the invariant it must preserve. That module is the single source of truth.

- **It is drift-checked.** `test/image_pipe/twicpics_source_inventory_test.exs`
  decodes every file and fails if the inventory and the bytes disagree, if a source
  is added or removed without an entry, or if a `Constellations` source is not
  inventoried. Adding, removing, or regenerating a source means updating its entry —
  the test enforces it.

### Source-hosting handshake (catbox)

Sources are hosted on catbox and served to the live oracle through the
`imagepipe.twic.pics` catch-all path. The committed source bytes **must equal the
hosted bytes**: TwicPics renders the hosted file, not the local one, so a mismatch
means ImagePipe and TwicPics are rendering different inputs.

The bake verifies this automatically: for each source it downloads the bytes from the
`source_bytes_url` recorded in `SourceInventory` and compares their SHA-256 to the
committed file. If they differ it raises before fetching any oracle output.

The seed source (`grid_4x4.png`) is a 400x400 RGBA colour grid from the #321 focus
probe, uploaded to catbox and served via
`https://imagepipe.twic.pics/b7g72c.png`. When adding a new source, upload it to
catbox and record its `source_bytes_url` in `SourceInventory`. The bake's
`resolve_sources/1` handles the upload automatically for entries without a recorded
`hosted_url`.

## Incremental bake

The oracle signature is `{chain, output suffix, source-byte identity}`. A case is
skipped (zero requests) when all three hold:

1. The signature matches the prior manifest entry.
2. The committed reference PNG is present.
3. The PNG's SHA-256 matches the manifest's recorded hash.

A no-op re-bake (nothing changed) is idempotent: `baked_at` is preserved and no git
churn is produced. `--force` re-bakes everything; `--only id1,id2` re-bakes specific
cases and keeps all others from the prior manifest (no requests for unlisted cases).

The bake prunes orphaned manifest entries and reference PNGs when a constellation is
deleted — run it after removing a case to clean up.

## Visual-diff report (no network)

Generate a self-contained `report.html` for eyeball triage — oracle vs ImagePipe
side by side, the decoded cell-maps for both, and informational heatmaps where dims
match:

```shell
mise exec -- mix twicpics.gen_report             # writes report.html here
mise exec -- mix twicpics.gen_report --out /tmp/r.html
```

It renders ImagePipe live and reads the committed fixtures — no network, no fixture or
manifest changes. The default `report.html` is gitignored. Triaged/quarantined cases
are included in the report (they are the ones most worth eyeballing).

## Triage a bake (no network)

When a case fails the conformance lane, `mix twicpics.diagnose` prints a one-line
structural summary per constellation — output dims, band count, and a PASS/MISMATCH
verdict — by rendering ImagePipe live against the committed structural record:

```shell
mise exec -- mix twicpics.diagnose cover_wide contain_tall   # specific cases
mise exec -- mix twicpics.diagnose                            # whole suite (non-triaged)
```

**Reading it — skew vs structural.** A `:ambiguous` sample (the nearest cell is
beyond the tolerance distance) or a `low_confidence_samples` warning at bake time is
a decode-confidence issue — consider widening the `color_dist` tolerance on the
constellation, or investigate whether a lattice-boundary artifact is causing the
margin guard to flag it. A **shifted cell** (the decoded cell index is wrong, not just
ambiguous) is a genuine placement divergence; never widen tolerance to hide it.

**Tolerance** (`tol: %{color_dist, alpha}` on the constellation; defaults are in
`StructureCompare.default_tol/0`):

- `color_dist` is the maximum squared RGB distance for a confident nearest-cell match
  (sum of per-channel squared diffs, 0..3x255²). Beyond it a sample is `:ambiguous`.
- `alpha` is the maximum alpha value (0..255) counted as transparent padding.

After changing only a `tol`, refresh the authored hashes with `mix twicpics.reauthor`
(no network) rather than re-baking.

## Quarantine mechanism

A constellation can be quarantined while a discrepancy is being triaged: set a
`:triage` key on its constellation map (a short reason + tracking issue). The
comparison test tags it `:twicpics_triage`, which `test/test_helper.exs` excludes by
default, so a plain `mix test` stays green and the case shows as skipped rather than
failed. Run the quarantined cases with:

```shell
MIX_ENV=test mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs --include twicpics_triage --only twicpics_triage
```

`:triage` is not an authored field, so quarantining or un-quarantining alone does not
require a manifest reauthor. The bake still fetches oracle output for triaged cases
(the parse gate skips them, but the bake runs them — only the conformance comparison
is quarantined).

**Current quarantined cases (2)**, both tracked under
[#323](https://github.com/hlindset/image_pipe/issues/323):

- `cover_ratio_tall` — lattice-boundary artifact: a centered 2:3 crop on the square
  source lands the cell-centre samples on a cell-column boundary; a <=1px
  crop-centering rounding difference flips the decoded cell, and the low-confidence
  margin guard flags it. Not a placement bug.
- `crop_region_reset` — genuine placement divergence: `crop@coords` focus-reset +
  trailing guided `crop=80x80` positions the window approximately half a cell toward
  `(3,3)` vs TwicPics' `(2,2)`. The reset itself works; exact positioning differs.

## Reauthor does not prune

`mix twicpics.reauthor` refreshes the `authored_sha256` for every manifest entry from
the current constellation list. It does **not** prune orphaned entries or reference
PNGs. If you delete a constellation, re-bake (`mise run twic:bake`) to remove its
manifest entry and PNG.

(`reauthor` raises with a clear message if an entry has no matching constellation, so
you cannot silently accumulate orphaned entries.)

## Negative-focus rejection is out of scope

TwicPics 404s on negative-coordinate focus (`focus=-1x-1`); ImagePipe 400s. There is
no grid to decode from either response, so this contract cannot be exercised by the
structural suite. It is covered by the TwicPics parser unit/wire tests
(`test/image_pipe/twic_pics_wire_conformance_test.exs`).

# Golden images

Whole-image goldens baked from ImagePipe's own output, compared by
`test/image_pipe/api_golden_test.exs`. They cover what the imgproxy reference
suite can't: ImagePipe-only options, deliberate differences from imgproxy,
output encoding and colour handling.

- `cases.ex` lists the cases: the native request, the source, the tolerance,
  and for some, `changes_with`: the issues whose fix is expected to change them.
- `fixtures/` holds the decoded output of each case as a PNG.
- `manifest.exs` records the libvips version used for baking, the SHA-256 of
  every source, and each fixture's SHA-256 and output structure.

A golden records current behaviour, bugs included: a failure means the output
changed, not that it is wrong. Comparison works as in the imgproxy reference
suite: `{threshold, budget}` tolerances, alpha compared premultiplied, and an
output, difference image and result per case in `tmp/golden/`, which
`mix image_pipe.pixel_report --suite golden` turns into a page. Lossy formats
(`:encoded` cases) compare decoded pixels with a wider tolerance.

A fixture is decoded and re-saved, which loses the encoded output's profile
and metadata, so the bake also records each output's structure from the
response: content type, bands, alpha, interpretation, depth, ICC profile
(description and SHA-256), orientation, and any EXIF, XMP or IPTC beyond the
tags libvips writes on every save. The test fails when any of it changes.

## Baking

    MIX_ENV=test mise exec -- mix image_pipe.golden.bake [--only id,id]

It renders through ImagePipe, so it needs no Docker. Without `--only` it re-bakes
every case and removes orphaned fixtures.

## Change rules

- Re-bake only when a change to the output is intended, and review every changed
  image and structure in the diff. The commit says why the output changed.
- In a change made for an issue, only goldens whose `changes_with` names it
  should move. Any other golden that changes is a regression until explained.
  Once the change lands, drop that issue from `changes_with`.
- Sources must stay byte-identical; the integrity test checks them against the
  manifest.
- Baking runs on whatever branches the workspace has applied. Check that the
  baked behaviour matches the branch the goldens are committed to.

# Imgproxy pixel references

Reference outputs baked by upstream open-source imgproxy, compared against
ImagePipe by `test/image_pipe/api_imgproxy_reference_test.exs`. The test sends
each case's native request through ImagePipe's URL API; no imgproxy code
participates.

- `cases.ex` lists the cases: the native request, the imgproxy request the
  fixture was baked from, the tolerance, and a comment on what the case
  targets.
- `fixtures/` holds one PNG per `:png` case. `:lossy` cases have no fixture;
  they compare dimensions and content type.
- `manifest.exs` records the generator (`imgproxy_image`, pinned by digest, and
  its `imgproxy_libvips`), the SHA-256 of every source the fixtures were baked
  from, and each case's fixture SHA-256 or expected lossy dimensions and
  content type.

Watermark cases use `alpha.png` as the asset on both sides: imgproxy's
`IMGPROXY_WATERMARK_PATH` and ImagePipe's `mark` watermark.

`mix imgproxy.bake` renders the cases through the pinned imgproxy container
and writes fixtures and the manifest; its moduledoc has the command. It needs
Docker.

Every case writes its output, an amplified difference image and its result
to `tmp/imgproxy_reference/`. `mix imgproxy.report` turns them into one
self-contained HTML page: failures first, then passing cases sorted by how
much of their tolerance they used. CI runs the suite as its own
`imgproxy reference tests` step in one job (the module is tagged
`:imgproxy_reference`), uploads the page unzipped on every run, and adds the
cases with the least headroom to the job summary.

A tolerance `{threshold, budget}` allows at most `budget` band samples to
differ by more than `threshold` levels. Images with alpha compare
premultiplied, since colour under transparent pixels is invisible. When imgproxy
returns a grayscale result promoted to sRGB, ImagePipe's 1- or 2-band output is
converted to sRGB before comparing. The default is `{2, 64}`; wider
tolerances are explained in the case comment.

## Change rules

- Fixtures are evidence of imgproxy's behaviour. Never re-bake or edit one to
  accommodate an ImagePipe change; the integrity test fails if fixture bytes
  change. Re-bake only to add cases (`--only`) or to upgrade the pinned
  imgproxy, and review every changed fixture.
- If ImagePipe differs from a case: fix ImagePipe when it is wrong, marking
  the case `pending` with the issue until the fix lands. When the difference
  is intended, remove the case, its fixture and its manifest entry, and give
  the reason in the commit.
- Sources the fixtures were baked from must stay byte-identical. The integrity
  test checks them against the manifest; see `SourceInventory` before
  regenerating sources.
- Only add cases baked from open-source imgproxy.

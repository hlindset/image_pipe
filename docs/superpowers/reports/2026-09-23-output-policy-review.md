# Output negotiation, encoding, and terminals

Investigation: `image_plug-6z9.9`. Implementation: `image_plug-6z9.9.1`.

## Responsibilities and boundaries

- `Plan.Builder.OutputOptions.schema/0` validates caller-supplied output options;
  `Plan.Request.Output` retains sparse intent. Per-format option structs own
  shared field schemas and sparse merging (`image_plug-9gj`).
- `Output.RequestPolicy.resolve/3`, called by `Processing.prepare/3`, combines
  intent with validated host defaults, checks effective HDR/profile and search
  constraints, and negotiates modern candidates. Explicit formats bypass Accept;
  automatic image output varies on Accept even when no modern candidate exists.
  `Policy.ensure_capable/2` rejects unsupported explicit encoders before fetch.
- `Output.Policy` holds decisions that can precede source fetch. Its
  `identity_selection/1` and `identity_material/1` feed `Execution.Identity`.
  `resolve/2` selects a concrete `Output.Resolved`: explicit output, the first
  accepted available modern codec, baseline source format, or JPEG/PNG selected
  from final alpha. `supports_hdr?/2` supplies input-conditioning policy.
- `Processing` combines encoder and host result limits, invokes `Clamp`, and
  passes the resolved output to `Encoder.stream_output/4`. The encoder owns
  materialization, flattening, ICC export/conversion, metadata, writer options,
  and lazy versus searched output. Quality-search probes reuse finalization via
  `encode_to_buffer/3`; search algorithms belong to investigation `6z9.10`.
- `Processing.Terminal` owns decode/execution orchestration for placeholders and
  source info. BlurHash and LQIP share `Output.Terminal.PixelSpace`; the executor
  owns their display-frame reduction. Info reads source geometry and orientation
  without running transforms. Terminal identities enter representation identity;
  terminals bypass image policy and Accept negotiation.

## Safe To Patch Now

1. **Exact MIME negotiation** (`Negotiation.acceptable?/2`). Matching grouped
   every header entry into specificity buckets, then searched only `[:exact]`.
   A direct exact-match comprehension expresses the actual contract and removes
   four helpers. Keep canonical MIME normalization, positive acceptance, duplicate
   zero-weight veto, malformed-weight fallback, capability filtering, and server
   preference order. Simplify the property oracle's corresponding scaffold too.
2. **Trusted encoder format lookup** (`Encoder.output_format/1`). Production
   `Resolved` values come from `Policy.resolved/2`; explicit formats are validated
   by the builder, modern candidates come from the known-format table, and the
   source/alpha fallbacks yield JPEG or PNG. Direct canonical MIME/suffix lookup
   removes the unsupported-internal-atom error helper and redundant result
   plumbing. Real unsupported-codec checks and native error translation remain.

Both are implemented in `image_plug-6z9.9.1`. Existing example, property, and
wire tests cover the unchanged contracts; no internal-misuse tests are added.

## Retained design and risks

- Keep sparse intent, effective policy, and resolved settings separate: merging
  them would mix pre-fetch identity with source-dependent choices. In particular,
  source-only and unaccepted modern source formats need final-alpha fallback.
- Keep per-format writer tokens concrete. Shared validation already lives in
  the option structs; a generic encoder framework would add indirection across
  four short mappings. Preserve Image and Vix writer paths and PNG's lossless
  implicit default; explicit quality may intentionally quantize PNG.
- Keep profile import/export ownership separate from metadata retention. Source
  ICC backup, requested target conversion, HDR depth, EXIF field enumeration,
  and copyright preservation have distinct effects. Metadata helpers cross a
  native boundary; do not delete their failure handling as internal validation.
- Keep clamp's iterative pixel check and one-pixel floor. Rounded dimensions
  can exceed a pixel cap even when the requested scale was mathematically valid.
- Keep terminal dispatch concrete. Two small execution/reduction sequences do
  not justify a callback registry. LQIP removes source tags before its dependency
  thumbnails already-oriented/imported pixels; BlurHash's normalization also
  supports direct images with retained ICC. Their metadata paths differ for a
  reason.
- Keep buffering and materialization unchanged. Altering native realization or
  writer paths requires comparable-preload latency and memory evidence under the
  project's speed-first performance rule.

## Related work

`image_plug-9gj` already consolidated encoder constraints. No duplicate follow-up
is needed. `image_plug-ysj` (additional output formats), `image_plug-rj6` (CMYK),
`image_plug-154` (DPI), and `image_plug-0f2` (raw/skip-processing) remain separate
capability proposals requiring their own design. This cleanup does not introduce
dependencies on them. Quality-search algorithm review remains in `6z9.10`.

## Validation

- Before edits: negotiation examples/properties, output policy, and encoder
  suites passed (60 tests, 2 properties).
- After edits: output, negotiation, policy, encoder, Plug, quality, metadata,
  color-management, and terminal wire suites passed (290 tests, 11 properties).
- Full `mise run precommit` passed: format, compilation with warnings as errors,
  Credo, Dialyzer, duplication check, and 2,530 tests/properties (5 optional
  integration exclusions).

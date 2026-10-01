# Architecture

The [API semantics](../../image_pipe/docs/api_contract.md) define public behavior.
These notes describe runtime ownership and contributor verification requirements.

- [Execution flow](execution_flow.md): request lifecycle, generation, and delivery.
- [Transform internals](transform_operations.md): geometry, state, and materialization.

## Request and output data

Canonical request data lives in `ImagePipe.Plan.Spec`, with explicit
`Plan.Spec.Group` transform intent and sparse `Plan.Spec.Output` policy.
The parser validates URL grammar and translates it into typed intent.
The [Elixir builder API](../../image_pipe/docs/elixir-api.md) constructs processing plans and validates native option values.
Both use `Plan.Spec.Validation` for cross-option rules; its typed issues
are mapped to URL byte spans and messages by the parser.
`Plan.Spec.build/2` owns canonical construction, group defaults, and identity
normalization. Both frontends share the resulting values with execution.
URL parsing returns the decoded source separately from processing intent;
both frontends resolve their source before handing it to shared execution.
`Output.RequestPolicy` combines host defaults,
request overrides, and Accept negotiation. `Output.Resolved` selects the concrete
encoding settings after source-format and final-image inspection.

## Verification

The Plug lifecycle calls parsing, source resolution, representation
identity, execution, and delivery. Parsing produces request groups and output
intent; the executor owns fixed ordering and runtime geometry. `Source`,
`Output`, and `Response` own their respective data and effects.

Preserve these invariants:

- Signature/expiry/static validation precede source fetch and cache access.
- Conditional responses can complete before fetch, decode, encode, or cache
  reads when a trustworthy source identity is available.
- Cachebuster and vary inputs affect storage identity; they do not change
  a byte-identical representation's ETag. Safety limits gate generation.
- Only successful encoded results are cached; cache failures fail open.
- EXIF, color/HDR, shrink-on-load, and per-operation materialization retain
  pixel tests. Sequential safety is proved with genuinely streamed input.
- Delivery owns stream/resource cleanup on success and failure.
- Telemetry changes update both the default Logger and trace Capture.

Selected imgproxy comparisons provide test references for shared behavior;
ImagePipe semantics govern differences.

API coverage must exercise real requests and decoded pixels, alongside
parser tests. Keep AGENTS.md, boundary declarations, and architecture tests
aligned with the implementation.

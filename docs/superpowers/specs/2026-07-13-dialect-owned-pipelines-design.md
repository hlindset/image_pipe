# Dialect-owned pipelines — design

**Status:** approved direction, pre-probe
**Date:** 2026-07-13
**Relations:** supersedes the Architecture section of
`2026-07-12-native-url-dialect-design.md`; reframes #262's satisfier as a
plain helper; subsumes the strategy-SDK demotion question (the SDK dies with
the framework it belongs to).

## Motivation

The current architecture routes every dialect through a neutral choke point:
parser behaviour → neutral `Plan` → shared orchestration → resolver-strategy
dispatch → transform lowering → execution. A simple `w:800` request traverses
~14 hops across ~8 concept families, and debugging one geometry question can
touch six files. Successive flattening passes (#449, #451) improved the hops
without reducing the concept count, because the indirection is structural:
it exists to let dialect logic pass through neutral seams (strategies,
markers, `Directive`, renderer dispatch) and to keep options open for external
dialect authors who don't yet exist.

The inversion: a dialect stops being a parser plugged into ImagePipe's
pipeline and becomes **a pipeline assembled from ImagePipe's toolkit**. Its
request path is a visible, top-to-bottom chain in its own module:

    parse → validate → canonical request data → key/ETag → conditional check
    → fetch → decode-plan → transform ops → encode/terminal → cache write
    → deliver

Roughly fifteen explicit lines per dialect, calling shared stage functions
directly. The trade, in one sentence: fifteen lines of readable duplication
per dialect instead of a dispatch framework nobody can trace. At one-to-three
dialects, duplication wins.

Consequences:

- TwicPics-style ordered geometry becomes ordinary sequential code inside
  that dialect. No carried strategies, no `Directive`, no `:deferred`
  markers, no `rewrap/2`, no strategy SDK.
- IIIF's `info.json` is a branch in IIIF's pipeline. No `Renderer` dispatch.
- The `Plan.Operation.*` / `Transform.Operation.*` mirror collapses: a
  dialect hashes its own canonical request struct for the key, then builds
  transform ops directly.
- The external-dialect story becomes honest by construction: an external
  dialect owns its pipeline and can do anything without core changes; what
  remains is contract conformance.
- Keeping the imgproxy dialect stops taxing the core — each dialect pays its
  own way. The keep/drop decision becomes a per-dialect product question with
  no architectural coupling.

## Responsibility split

**ImagePipe core** — everything that must be true regardless of URL grammar:

- The pixel engine: transform ops, `State`, chain execution, materialization,
  orientation flush, decode planning (shrink-on-load), sequential-safety
  proofs. Unchanged.
- I/O: source adapters, cache adapters + incremental sink, streaming delivery
  (`Producer`/`PreparedStream`), `Response.Sender`.
- Safety **inside** the primitives: `max_body_bytes` enforced by fetch itself,
  `max_input_pixels` by decode itself. Unskippable, not a contract.
- HTTP mechanics as pure helpers: `Accept` negotiation + `Vary`,
  conditional-GET evaluation, error taxonomy → status mapping,
  disposition/debug-header builders.
- Key/ETag toolkit with the storage-identity vs validator distinction built
  into the constructors (see Enforcement).
- Telemetry span helpers and the standard stage names, so the Logger and OTel
  surfaces don't fragment per dialect.
- The contract test kits (in-repo test support).
- The native dialect — both product and canonical worked example.

**A dialect** — grammar + semantics + assembly:

- Parse and verify its URL scheme (its own signature mechanics).
- Its own canonical request struct.
- Translation to transform ops, geometry policy inline (ordered or
  declarative — its business).
- The visible pipeline chain.
- Key/ETag data composition from core builders, satisfying the contracts.
- Error rendering (bodies); dialect-specific response headers.
- Its docs, wire tests, and contract-kit runs.

## Seam map

| Today | Fate |
| --- | --- |
| `Transform.*`, `Source.*`, `Output.*`, `Response.*`, `Cache.*` | Core toolkit, largely as-is; exports widen — dialects may name concrete transform ops (deliberate reversal of today's boundary rule) |
| `Request.*` | Dissolves: orchestration moves into dialects; reusable pieces become stage helpers (conditional evaluation, request span) |
| `Plan.*` | Shrinks to shared value types (`Color`, px/pct/ratio units, `Output` config). The neutral interchange program dies |
| `Resolver`, strategies, `Directive`, `:deferred`, `{:effective, …}` | Die — dialect-inline code |
| `Renderer` | Dies — dialects return non-image bodies from their own pipelines |
| `Parser.*` | Dialects become peers: `ImagePipe.Dialect.Native`, `.Imgproxy`, … each a self-contained pipeline module |

**Acid test, enforced by Boundary:** delete every dialect directory and the
core still compiles. Dependency direction is one-way — dialects depend on
core exports; core depends on no dialect; dialects cannot reach into each
other.

## Enforcement model

Behaviours are the framework-calls-you tool. Inversion is you-call-the-
framework, so the stack is different:

1. **A dialect is literally a Plug.** `init/1` validates config and raises;
   `call/2` runs the pipeline. Plug is the entry behaviour; nothing replaces
   `ImagePipe.Parser`. Hosts mount the dialect module directly.
2. **One-way typed stage data — the strongest lever.** Distinct structs per
   stage with `@enforce_keys` (`SourceIdentity` → `Fetched` → `Decoded` → …)
   make mis-sequencing loud. The critical instance: `CacheKey.build/…` and
   `ETag.build/…` accept only pre-fetch types (source identity, canonical
   request data, negotiated format) — no function exists that builds key or
   ETag from fetched bytes, so "ETag derivable before fetch" is enforced by
   what the API accepts, not by what dialects promise. Types prevent wrong
   order; they cannot prevent omission — that is layer 4's job.
3. **Hard primitives** for safety limits, as above.
4. **Executable contract kits** for what types can't carry:
   `use ImagePipe.ContractKit.CacheKey, dialect: …` generates tests for key
   determinism, vary-inputs-in-key-not-ETag, reject-never-touches-source
   (instrumented source), 304-before-fetch, telemetry stage naming. Each kit
   defines a small test-facing behaviour ("give me two equivalent requests",
   "give me a rejectable request") — the one legitimate home for behaviours
   in this design.
5. **Dialyzer specs and Boundary** as background enforcement.

Honest accounting: correctness that is structural today becomes
types-plus-tests. The one-way constructors recover the most safety-critical
invariants structurally; the kits cover semantic promises; the remainder is
review discipline — acceptable in-tree, and more honest than the current
strategy SDK is for externals.

## Decisions

- **Skeleton prescriptiveness: à la carte.** Core ships stage functions
  only; each dialect writes its own chain, copying the native dialect as the
  worked example. No `DefaultPipeline`, no override hooks — a shared
  orchestrator with callbacks would be the current framework rebuilt under a
  different name.
- **Contract kits live in `test/support` in v1.** They gate the in-tree
  dialects. Publish them (Plug.Test/Ecto-adapter style) only when a real
  external dialect author appears.
- **Probe scope: native dialect, full vertical slice.** See below.

## The probe

Build `ImagePipe.Dialect.Native` (the wire surface of
`2026-07-12-native-url-dialect-design.md`, or a core subset) as the first
inverted pipeline — parse through delivery, including key/ETag, conditional
GET, cache, and streaming — while the existing framework continues to serve
the other dialects untouched. Extract stage helpers and the first contract
kits from what the probe actually needs, not speculatively.

Probe rules:

- Parallel stacks: the framework path is not modified beyond widening core
  exports the probe needs. No dialect migrates during the probe.
- Extraction is demand-driven: a helper graduates to core when the probe
  needs it; nothing is designed for a hypothetical second consumer. The
  imgproxy migration (if it ever happens) is when native-shaped helpers get
  generalized.
- Duplication is allowed inside the probe first, extracted second.

Exit criteria:

- The native dialect serves real requests end-to-end through its own
  pipeline: geometry + effects, negotiation + `Vary`, signing, `then`
  groups, ETag/304 before fetch, cache hit/miss with the incremental sink,
  streamed delivery with cancellation.
- At least `ContractKit.CacheKey` and `ContractKit.RequestSafety` exist and
  pass against the native dialect.
- A hop-count/concept-count comparison of the same request through both
  stacks — the followability claim, measured.
- A written list of core exports the probe needed, as the draft of the real
  toolkit surface.

## Non-goals (probe phase)

- Migrating imgproxy, TwicPics, or IIIF onto the pattern.
- Deleting the framework, `Plan`, `Resolver`, or `Renderer` — coexistence
  until a migration decision is made per dialect.
- Publishing contract kits or any external-dialect SDK.
- Cross-dialect cache-entry sharing (dies by design; a deployment mounts one
  dialect).

## Risks

- **Skeleton drift** between dialects once more than one is inverted —
  mitigated by contract kits and chunky stage functions, accepted at N≤3.
- **Omission gap**: types can't force a dialect to run a stage (e.g. the
  conditional check). Contract kits cover the known-critical omissions; new
  invariants need new kit cases.
- **Coexistence tax**: two stacks in-tree until migrations complete. Bounded
  by the probe's parallel-stacks rule and by the fact that wire-level tests
  (including the imgproxy differential suite) are black-box and stack-
  agnostic.
- **Cross-cutting evolution** (a new pipeline-wide feature touches every
  dialect) — the deliberate price of visible flow; cheap at small N.

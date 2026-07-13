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

    parse → validate → canonical request → representation (key/ETag)
    → conditional check → cache lookup → fetch/open → probe header
    → plan geometry + decode plan → decode → transforms → terminal
    → cache write → deliver

Roughly fifteen explicit lines per dialect, calling shared stage functions
directly. The trade, in one sentence: fifteen lines of readable duplication
per dialect instead of a dispatch framework nobody can trace. At one-to-three
dialects, duplication wins.

Consequences:

- TwicPics-style ordered geometry becomes ordinary sequential code inside
  that dialect. No carried strategies, no `Directive`, no `:deferred`
  markers, no `rewrap/2`, no strategy SDK. The complexity does not vanish —
  an ordered dialect still runs a two-phase pipeline (canonicalize and hash
  before fetch; plan geometry against realized dimensions while executing)
  and may contain a small sequential interpreter. The win is that it is
  local, uses ordinary functions and state, and emits transform ops directly
  instead of speaking a generic resolver protocol.
- IIIF's `info.json` is a branch in IIIF's pipeline. No `Renderer` dispatch.
- The `Plan.Operation.*` / `Transform.Operation.*` mirror collapses: a
  dialect hashes its own canonical request struct for the key, then builds
  transform ops directly.
- The external-dialect story becomes honest: an external dialect is an
  independent Plug built on semipublic ImagePipe primitives. ImagePipe
  guarantees the primitives — not the correctness or upgrade stability of
  arbitrary assembled pipelines. This is Ecto-adapter/Plug-style
  extensibility, not a parser SDK.
- Keeping the imgproxy dialect no longer imposes shared control-flow
  machinery on the core. It may still pressure the curated toolkit surface
  and remains a substantial dialect-specific maintenance commitment; the
  keep/drop decision becomes a per-dialect product question with no
  architectural coupling.

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
- The `Representation` builder: dialects supply categorized identity
  material; core alone derives storage key, ETag, and `Vary` from it (see
  Enforcement).
- Telemetry span helpers and the standard stage names, so the Logger and OTel
  surfaces don't fragment per dialect.
- The contract test kits (in-repo test support).

**First-party dialects** — shipped in this repository but dependency-wise
ordinary dialects: `ImagePipe.Dialect.Native` (the canonical worked example)
and whichever compat dialects survive their per-dialect product decisions.
The dependency arrow is `Dialect.Native → Core`, never the reverse.

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
| `Renderer` | Generic dispatch dies. Shared terminal computations remain core toolkit stages; protocol renderings (IIIF `info.json`) remain dialect-owned |
| `Parser.*` | Dialects become peers: `ImagePipe.Dialect.Native`, `.Imgproxy`, … each a self-contained pipeline module |

**Acid test, enforced by Boundary:** delete every dialect directory —
including the native dialect — and the core still compiles. Dependency
direction is one-way — dialects depend on core exports; core depends on no
dialect; dialects cannot reach into each other.

## Source-dependent planning

The operation mirror dies; source-dependent planning does not. Dialects
perform it locally, after probing and before or during transform execution:

- After `fetch/open`, core exposes the probed source header (format,
  dimensions, orientation, animation) **in a defined orientation frame** —
  display-frame geometry with the EXIF policy already accounted for, so
  dialects plan against what the user will see and never rediscover the
  storage/display frame compensation that the orientation-flush machinery
  (#146) owns.
- A declarative dialect builds its full operation list from the canonical
  request plus probed header, then asks core for the decode plan:
  `DecodePlanner.plan(source_info, operations, terminal_hint)`. The
  `terminal_hint` keeps shrink-on-load terminal-aware — a pixel-tapping
  complete terminal's final reduction (e.g. a tiny LQIP frame) logically
  follows the user transforms but must still inform the load-time shrink
  factor (#377's regression to guard).
- An ordered dialect may instead interleave: compute an operation, execute,
  measure realized dimensions, update local state, compute the next. That
  loop is dialect-local ordinary code — no generic callback seam — but it is
  a real second phase, and the decode plan it can exploit is limited to what
  is known before pixel decode.

## Enforcement model

Behaviours are the framework-calls-you tool. Inversion is you-call-the-
framework, so the stack is different:

1. **A dialect is literally a Plug.** `init/1` validates config and raises;
   `call/2` runs the pipeline. Plug is the entry behaviour; nothing replaces
   `ImagePipe.Parser`. Hosts mount the dialect module directly.
2. **One-way typed stage data — used with restraint.** A stage type is
   introduced only when it owns a resource, closes a meaningful construction
   boundary, or prevents a concrete class of severe error. Good candidates:
   source identity, fetched source/session, decoded image ownership,
   negotiated representation, prepared stream, the `Representation`
   artifact. Not candidates: wrappers that merely prove a helper was called,
   or one type per pure metadata transformation — a full typestate ladder
   (`Parsed → Identified → Validated → …`) would rebuild the framework's
   concept count under another name. Sequencing omissions that would need
   artificial typestate are the contract kits' job instead.

   The critical one-way instance is representation identity:
   `Representation.build(source_identity, identity_material)` accepts only
   pre-fetch types and returns `%Representation{cache_key, etag, vary}` —
   no function exists that builds key or ETag from fetched bytes, so "ETag
   derivable before fetch" is enforced by what the API accepts. The dialect
   supplies **categorized** material (`%IdentityMaterial{representation: …,
   storage_only: …, vary_inputs: …, behavior_versions: …}`) and core alone
   derives storage key (all categories), ETag (representation +
   behavior_versions only — storage-only inputs like cachebusters and vary
   inputs are excluded, per the cache guidelines), and `Vary`. Dialects
   never concatenate key material themselves; misclassifying material is a
   categorization error visible in review, not a silent omission
   discoverable only by whichever cases a contract kit happens to test.

   Identity has two owners, and each versions what it owns. The dialect
   supplies **dialect behavior identity** (`{ImagePipe.Dialect.Native, 3}`);
   core **injects its own execution identity** — the core execution epoch
   (the successor of today's transform key data version), terminal behavior
   versions, encoder/config identity — so a core-owned byte-affecting change
   (transform rounding, orientation handling, encoder defaults) never
   depends on every dialect remembering to bump something.

   Negotiation enters identity as the **selected variant**, not the raw
   `Accept` header: two headers that both negotiate AVIF share a cache entry
   and an ETag, while `Vary: Accept` continues to describe HTTP selection.
   Contract kit cases: different headers selecting the same format share
   identity; different headers selecting different formats differ; an
   explicit output format ignores `Accept`; fixed-content-type terminals
   produce no `Vary`.

   Types prevent wrong order and wrong composition; they cannot prevent
   omission — that is layer 4's job.
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

## Design principles

Four principles that bound the inversion:

1. **Core helpers may own stage lifecycles — never the request lifecycle.**
   There are two kinds of orchestration: semantically meaningful dialect
   flow (duplicate it, visibly) and mechanically identical lifecycle
   management (never duplicate it). Resource cleanup on every failure path,
   cancellation propagation, cache-sink abort/finalize, producer ownership,
   telemetry span closure, lazy libvips resource cleanup, and
   double-response-send prevention are lifecycle mechanics: a dialect that
   hand-rolls them turns fifteen readable lines into nested `with` chains
   plus cleanup branches. Core ships chunky, lifecycle-owning primitives —
   bracket-style `Source.with_fetched(identity, opts, fun)` /
   `Decode.with_image(fetched, plan, fun)` — that own acquisition, cleanup,
   cancellation, telemetry closure, and error normalization for their stage.
   The dialect composes them; it never threads raw resources.

   The streaming corner case gets its own rule, because a lazy encoded
   stream outlives the function that prepared it: **a lifecycle-owning
   helper either retains ownership until all consumption completes, or
   explicitly transfers ownership into an owned, cancellable artifact**
   (`PreparedStream`/producer handle) that becomes responsible for cleanup.
   Lazy resources must never escape through an unowned function, stream, or
   closure; ownership transfer is visible at the call site and cleanup is
   idempotent. No ambiguous middle state where a callback returns a lazy
   factory still referencing resources the bracket believes it owns.
2. **Canonical request equality is a dialect contract.** Every dialect
   produces a pure canonical request value before fetch: deterministic data,
   free of PIDs/functions/references/conn state, normalized so semantically
   equivalent URLs yield equal values and byte-affecting differences **owned
   by the dialect request** yield different ones. Byte-affecting inputs the
   dialect does not own — host output config, source revisions, negotiation
   results, core behavior versions — enter representation identity through
   their own `IdentityMaterial` categories and core injection, not by being
   stuffed into the canonical request struct. A dialect may parse
   through any intermediate AST, but `IdentityMaterial` consumes the
   canonical value, never raw URL tokens. This contract replaces the
   canonicalization property the neutral Plan used to supply, and the
   CacheKey contract kit tests it.
3. **Transform exports are curated.** Dialects assemble pipelines from a
   stable semantic construction surface (operation structs and their
   constructors, geometry helpers, chain execution) — not from executor
   internals, `State` mutation seams, materialization machinery, or
   libvips-shaped arguments. The `Plan.Operation` constructors' validation
   and normalization (angle normalization, ratio canonicalization, typed
   px/pct dimensions, operation invariants) move into the transform-op
   constructors; collapsing the mirror removes representation duplication,
   not validation.
4. **Shared terminals remain toolkit functions.** Renderer *dispatch* dies;
   terminal *computations* don't move into dialects. Image encode — and
   later blurhash/LQIP (#377) — are reusable core stages a dialect selects
   and calls explicitly (a `case` on its own terminal value). Protocol-
   specific representations (IIIF `info.json`) stay dialect-owned. This
   keeps #262's tap-point insight without recreating `Renderable` dispatch.

The survival test for any shared helper: it must own a resource lifecycle,
enforce an invariant, perform a reusable computation, implement an HTTP or
cache mechanism, or supply a terminal/transform primitive. Anything whose
main purpose is "let dialect code be called later through a common
pipeline" is the old framework and must not survive.

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

Two narrow stress cases ride along, because native alone validates only the
toolkit's easiest consumer:

- **An ordered-planning spike.** One small synthetic TwicPics-like sequence
  — source geometry, carried local state, operation → execute → measure →
  next operation — not wired to any public route. It exists to validate that
  dialect-local ordinary code replaces the strategy framework without a new
  generic callback seam. Without it, the probe may produce a toolkit
  beautifully suited to native that cannot support the dialect used to
  justify the inversion.
- **A pixel-tapping complete terminal.** BlurHash, LQIP, or a trivial
  equivalent (average color), exercising terminal-aware decode planning,
  the shared transform prefix, complete-body result caching, fixed content
  type with no `Vary`, and cleanup without the streaming encoder path
  (#377/#262 made concrete).

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
- **A change-locality benchmark.** For three representative changes — add a
  transform option, add a pixel-tapping terminal, change cache-key material
  — record for each stack: modules touched, layers crossed, tests updated,
  and per-dialect duplication. The explicit flow should win geometry
  debugging; it may lose cross-cutting changes — measure both rather than
  assume.
- **Error-path completeness.** Exercise and document: fetch failure, client
  disconnect during fetch, decode rejection, transform failure after partial
  work, encoder failure after the first streamed chunk, cache lookup and
  write failures, producer cancellation, response-already-sent. Compare how
  many places own cleanup and error translation. If the dialect chain stays
  readable under these, the design has actually succeeded; if the happy path
  is clean but error paths fragment, the lifecycle primitives (Design
  principle 1) are under-chunked. Verify **ownership**, not only response
  behavior: who owns the source session after encode preparation, who closes
  it on normal completion, who aborts it on client disconnect, who
  finalizes or aborts the cache sink, and what happens when the encoder
  fails after the first chunk.
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

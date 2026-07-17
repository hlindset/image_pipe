# TwicPics dialect inversion design

**Date:** 2026-07-17

**Status:** Approved design. Implementation planning hasn't started.

**Precedent:**
[`2026-07-15-imgproxy-dialect-inversion-design.md`](2026-07-15-imgproxy-dialect-inversion-design.md),
[`2026-07-16-imgproxy-dialect-phase2-design.md`](2026-07-16-imgproxy-dialect-phase2-design.md)

## Objective

Build `ImagePipe.Dialect.TwicPics` as a self-contained Plug assembled from
ImagePipe's core toolkit. It first runs beside the frozen
`ImagePipe.Parser.TwicPics` framework stack under a dual-run conformance net.
After recorded gaps close under that net, the dialect becomes the sole
TwicPics stack and the parser-specific framework path is removed.

This inversion applies the imgproxy direction to an order-sensitive product.
TwicPics transformations are positional: each manipulation sees the result of
the preceding manipulations, and relative units resolve against the running
dimensions at that position. The dialect can't use imgproxy's
declarative, order-insensitive request shape.

The external compatibility target is the hosted TwicPics Image API, not the
current parser implementation. The parser is the local behavioral baseline
during the transition; committed SaaS fixtures and the TwicPics documentation
remain the upstream oracle.

## Scope

### In scope

- `ImagePipe.Dialect.TwicPics` as a Plug with a flat configuration surface.
- A dialect-local ordered request model and focus carry.
- Dual-running the frozen parser arm and the new dialect arm.
- Reusing the committed TwicPics SaaS fixtures without re-baking them for the
  inversion.
- Closing recorded stack divergences and defects in the currently supported
  TwicPics surface while both arms remain live.
- Making the dialect the sole TwicPics stack.
- Removing `ImagePipe.Parser.TwicPics` and its parser-owned helpers.
- Removing the geometry strategy SDK after its last product consumer retires:
  `ImagePipe.Resolver`, `ImagePipe.Plan.resolver`,
  `ImagePipe.Plan.Operation.Directive`, and the `:deferred` guide marker.
- Rewriting the host parser contract around product-neutral declarative Plans.
- Completing issue #457's core chain-helper and ExDNA-visibility work now that
  three inverted dialects expose the repeated shape.
- Keeping `docs/twicpics_support_matrix.md` synchronized with every observable
  compatibility change.

### Out of scope

- Moving IIIF off `ImagePipe.Plug`.
- Requiring complete coverage of the TwicPics Image API before retirement.
- Adding rejected or missing features merely because they look inexpensive, including
  `zoom`, `turn`, `flip`, `noop`, conditional resize variants, color chaining,
  refit, placeholders, or video.
- A shared generic dialect runner.
- Re-baking a differential fixture to make an implementation failure pass.
- An implementation plan in the design session.

## Inputs and ground truth

### Upstream TwicPics behavior

The primary upstream sources are:

- <https://www.twicpics.com/llms.txt>
- <https://www.twicpics.com/llms-full.txt>
- the linked API pages indexed by those files
- black-box results from the hosted TwicPics Image API

Three upstream rules constrain the architecture:

1. Coordinates are zero-based. On a 640×480 image, the pixel corners are
   `0x0` and `639x479`.
2. Manipulations execute in URL order. A later `p` or `s` operand resolves
   against the dimensions produced by the preceding manipulations.
3. TwicPics may discard an earlier manipulation when a later manipulation
   fully shadows it. Its documented example treats
   `resize=50p/resize=340` as `resize=340`, not as two executed resizes.

The third rule exposes a current ImagePipe defect: the parser executes both
resizes, and its no-enlarge behavior leaves the example at 200×200 instead of
TwicPics' 340×340. The support matrix currently calls static chain collapse an
optimization rather than correctness. The inversion baseline must record this
as a behavioral divergence and close it under the live two-arm net.

The no-enlarge policy isn't itself a known divergence. A live probe against
the committed 400×400 grid source returned 400×400 for both `resize=600` and
`resize-min=600`, while `resize=200` returned 200×200. The existence of the
conditional `resize-min` transformation isn't evidence that plain `resize`
enlarges. The oracle prerequisite adds the supported `resize=600` case so this
observed behavior stops being an untested assumption.

The compatibility reviewer must check the design and later implementation
against those upstream sources and live behavior. Agreement with
`Parser.TwicPics` alone is insufficient when the parser and TwicPics disagree.

### Repository conformance sources

- `docs/twicpics_support_matrix.md` owns supported, partial, rejected, missing,
  and deliberately divergent surface claims.
- `test/image_pipe/twic_pics_wire_conformance_test.exs` pins observable request
  behavior and manipulation ordering.
- `test/image_pipe/twicpics_differential_conformance_test.exs` compares local
  rendering with committed hosted-TwicPics output.
- `test/support/image_pipe/test/twicpics_differential/README.md` owns fixture
  provenance, bake, diagnosis, tolerance, verdict, and quarantine procedure.
- `test/support/image_pipe/test/twicpics_differential/source_inventory.ex`
  owns the committed source inventory and hosted-source identity.

The current authored constellation set contains 37 fixtures, five monitored
`:diverges` cases, and no `:triage` quarantines. The differential README still
contains an older 30-fixture/two-divergence census. Phase 1 corrects that drift
and makes the census assertion-backed or generated where practical.

## Current architecture

`ImagePipe.Parser.TwicPics` currently parses the ordered chain into a shared
`ImagePipe.Plan`:

```text
?twic=v1/focus=.../resize=.../crop=...
    │
    ▼
Parser.TwicPics
    │
    ├── Plan.Operation.Directive(:set_focus)
    ├── Resize(guide: :deferred)
    ├── CropGuided(guide: :deferred)
    └── Plan.resolver = Parser.TwicPics.Resolver
    │
    ▼
Transform.Executor
    └── Resolver + PointFlow carry the focus through emitted operations
```

The model reproduces TwicPics' positional focus behavior, but the private
dialect state crosses shared framework vocabulary:

- `Directive` places a no-pixel message in a Plan operation stream.
- `:deferred` marks a guide that only the TwicPics resolver can substitute.
- `Plan.resolver` selects product-specific runtime dispatch.
- `ImagePipe.Resolver` and executor continuations carry product state through
  neutral lowering and measured stages.

The imgproxy inversion established the stronger boundary: product-specific
runtime carry belongs in the product pipeline. TwicPics is the last in-tree
consumer of the strategy vocabulary, so its retirement exposes the framework
cleanup that imgproxy couldn't perform while TwicPics remained.

## Dependency inversion gate

The phase-1 architecture passes only if both statements hold:

1. Core ImagePipe modules don't name TwicPics.
2. `ImagePipe.Dialect.TwicPics` doesn't depend on `ImagePipe.Parser`,
   `ImagePipe.Request`, `ImagePipe.Resolver`, `ImagePipe.Renderer`, or another
   product dialect.

The dialect may depend on product-neutral core boundaries such as `Cache`,
`Config`, `Decode`, `Delivery`, `Error`, `Output`, `Plan`, `Representation`,
`Response`, `Source`, `Telemetry`, `Transform`, and `Format`, plus the
product-neutral `ImagePipe.Dialect.SharedConfig` helper. It may reuse a neutral
Plan operation struct as a semantic input. It doesn't construct a `%Plan{}` or
use the Plan strategy vocabulary.

Boundary tests enforce the declared dependency direction before phase 1 exits.
Because the Plan boundary root remains reachable when the dialect uses Plan
operation structs, a syntax-aware rule in
`test/image_pipe/architecture_boundary_test.exs` separately rejects Plan struct
construction under `lib/image_pipe/dialect/twic_pics/**`. The rule resolves
aliases and recognizes both `%Plan{}` and `%ImagePipe.Plan{}` forms; the Boundary
declaration alone can't enforce this clause.

## Decisions

| ID | Decision | Reason |
| --- | --- | --- |
| T1 | `ImagePipe.Dialect.TwicPics` is a self-contained Plug. | The product owns its request chain and depends inward on core. |
| T2 | The dialect request contains an ordered semantic step stream. | TwicPics meaning depends on manipulation position; a declarative option bag would erase behavior. |
| T3 | Focus carry is pipeline-local. | Runtime positional state doesn't belong in shared Plan markers. |
| T4 | The framework strategy SDK retires after the one-way transition. | With all product-specific runtime pipelines inverted, host parsers return only product-neutral declarative Plans. |
| T5 | Phase 1 uses frozen SaaS fixtures plus an exact cross-arm comparison. | SaaS tolerance must not hide a regression introduced by the dialect copy. |
| T6 | Gap closure covers recorded stack gaps and supported-surface defects, not the complete TwicPics API. | Retirement is an architectural transition, not an unbounded compatibility program. |
| T7 | Issue #457 uses the existing output negotiation seam, a new Response→Representation header seam, and definition-level ExDNA suppression. | The neutral decisions move to core while irreducible product chains remain visible. |
| T8 | No generic dialect runner is introduced. | Native, imgproxy, and TwicPics share lifecycle nouns but not one observable control-flow contract. |
| T9 | IIIF remains on the framework stack. | Its parser, id resolver, redirect, and renderer contracts are outside this inversion. |
| T10 | A differential re-bake is never an implementation fix. | Changing the oracle while changing the implementation destroys the transition evidence. |
| T11 | TwicPics-local shadowing is allowed only through upstream-proven rewrites. | Literal order remains authoritative, but the dialect must reproduce cases where TwicPics discards an earlier manipulation. |
| T12 | A fixed neutral execution driver lands and is cross-checked before strategy injection disappears. | Neutral measured stages still need continuations after product carry retires. |
| T13 | ImagePipe doesn't replace the strategy SDK with a public dialect-pipeline SDK. | Host parsers end at neutral Plans; product-specific ordered Plugs own their orchestration without relying on dialect internals. |
| T14 | The inversion records a frozen oracle baseline commit before the dialect copy. | Fixture bytes, sources, manifest, and report stay byte-identical throughout copy and parity fixes. |

## Dialect structure

The exact module split is an implementation-planning decision, but ownership
must follow this shape:

```text
ImagePipe.Dialect.TwicPics
├── Config                 flat option validation
├── Path / Source          request extraction and source translation
├── Manipulation / Units   ordered grammar and exact unit parsing
├── Request / Steps        dialect-local semantic request
├── Identity               ordered cache/ETag material
├── Negotiation            output policy selection
├── Pipeline               decode preflight and ordered execution
├── PointFlow              focus carry through emitted geometry
└── Errors                 observable error rendering/classification
```

Phase 1 begins as a semantic copy of the parser modules. It changes ownership
and the PlanBuilder output seam, not the accepted grammar. Mechanical grammar
movement and behavioral pipeline work remain reviewable as separate batches.

### Configuration

`ImagePipe.Dialect.TwicPics.init/1` accepts one flat keyword list, matching the
other inverted dialects:

```elixir
ImagePipe.Dialect.TwicPics.init(
  sources: [...],
  quality: 80,
  detector: :default,
  max_body_bytes: 10_000_000
)
```

Configuration ownership is split three ways:

- `ImagePipe.Dialect.SharedConfig`: source/cache runtime options, safety
  limits, CORS, negotiation capabilities, result limits, and other options
  every dialect actually shares.
- `ImagePipe.Config`: neutral output, quality, metadata, color-profile, HDR,
  `autoquality`, and encoder options.
- `ImagePipe.Dialect.TwicPics.Config`: TwicPics-relevant product seams such as
  detector configuration and delivery extensions.

The config module rejects every key outside those sets at init time. It
preserves the current neutral defaults and validates `autoquality` combinations
before a request runs.

Phase 1 audits the framework options exercised by the TwicPics wire suite,
including detector configuration, strict detector availability, CORS, debug
headers, output capabilities, and result limits. A missing dialect config seam
is a recorded stack divergence, not a silent omission.

### Ordered semantic request

The parser validates the complete chain and produces a request with an ordered
list of semantic steps. Conceptually:

```elixir
%TwicPics.Request{
  source: source,
  steps: [
    %TwicPics.Step.SetFocus{operand: {:coord, {:px, 50}, {:px, 50}}},
    %ImagePipe.Plan.Operation.Resize{...},
    %ImagePipe.Plan.Operation.CropGuided{...}
  ],
  output: output_policy,
  response: response_meta,
  auto_rotate: true
}
```

This is a structural example, not a required public API. The implementation
may use a smaller private representation, but it must retain these invariants:

- Step order equals URL order.
- No normalization sorts or groups image manipulations by option name.
- A separate TwicPics-local optimizer may discard a shadowed step only when an
  upstream rule and a discriminating SaaS fixture prove the rewrite.
- Every invalid name, unit, expression, range, or incompatible shape rejects
  before source or cache access.
- A positional focus step remains visible in the stream even though it emits
  no pixel operation.
- Repeated output, quality, and debug settings preserve their current
  last-value-wins behavior. They may be accumulated outside the pixel step
  list because their current meaning is position-independent.
- The request contains no `Directive`, `:deferred`, or resolver module.

Keeping raw `{name, args}` pairs until execution is rejected. It would defer
grammar failures until after fetch. Collapsing manipulations into one option
map is also rejected because it can't distinguish `focus/resize/crop` from
`resize/focus/crop`.

## Local pipeline and focus carry

`ImagePipe.Dialect.TwicPics.Pipeline` walks the semantic steps from left to
right with local state:

```text
{Transform.State, SourceShape, focus_state}
```

The point is image state transformed with the image content:

- `SetFocus` resolves its anchor or coordinates against the running frame at
  that chain position and replaces the carried point.
- Relative focus units remain exact until they resolve against the running
  dimensions.
- Positive out-of-range focus coordinates clamp as the live API does;
  negative coordinates remain pre-fetch parse failures.
- Resize scales the point by the realized per-axis factor.
- Region and guided crops translate the point by the realized crop origin.
- Canvas extension translates the point by the realized embed offset.
- The orientation flush rotates or reflects the point with the image content.
- A later focus overwrites the previous point.
- A focus point survives multiple consumers.

Neutral semantic operations continue through `Transform.NeutralResolver` and
the shared lowering/execution primitives. The local PointFlow reads emitted
operations' pure geometry helpers so its trajectory agrees with execution. It
enumerates every reachable geometry-changing operation explicitly. A newly
reachable operation without a point rule raises as a core-contract error; it
must not silently carry a stale point.

### Smart focus

`focus=auto` remains a positional smart guide rather than a concrete carried
point. Its detector identity enters representation identity whenever detector
availability or model selection can change output. Detector-required failure
occurs before source fetch.

The current documented difference remains: TwicPics doesn't specify the
algorithm behind `auto`; ImagePipe uses its face-assisted attention behavior.
That accepted difference isn't a reason to weaken exact parser-vs-dialect
comparison, because both local arms must still behave identically.

### Pipeline scope

TwicPics currently has one ordered manipulation chain and therefore one local
pipeline scope. The pipeline seeds its shape and focus once, runs all ordered
steps, and flushes pending orientation at the request's transform boundary.
It must not import imgproxy's `-` pipeline reset rules or Native's `then`
grouping rules.

### Decode preflight

The dialect derives `DecodePlanner.Request` from the validated semantic steps
before fetch. The preflight and runtime assembly must converge on the same
lowered dimensions and ordering. Property or table-driven tests compare the
preflight result with the operations the runtime pipeline actually assembles.

The runtime repeats pure semantic assembly where required; it never re-parses
raw URL text after fetch.

### Semantics-preserving shadowing

The semantic request retains the literal authored steps. Before decode
preflight and runtime assembly, a TwicPics-local optimizer may derive an
execution stream with upstream-proven shadowed steps removed.

The first required rule covers the documented absolute-resize example:

```text
resize=50p/resize=340  →  resize=340
```

The optimizer isn't a general last-wins map. It mustn't cross a manipulation
that makes the earlier step observable, and every rewrite needs:

- an official TwicPics rule or a reproducible live-SaaS observation;
- a committed discriminating constellation;
- RED evidence on both current local arms before the correction;
- exact agreement between the corrected arms afterward.

Identity may conservatively retain the literal ordered stream, so equivalent
requests can occupy separate cache entries. A later optimization may
produce one identity for proven equivalents, but cache compaction isn't required for
behavioral parity.

## Request lifecycle

The visible image chain is:

```text
method and CORS
→ path/query extraction
→ ordered manipulation parse
→ static geometry and detector-capability checks
→ source translation and identity resolution
→ output-policy and `Accept` selection
→ representation identity
→ conditional GET
→ cache lookup
→ fetch/decode
→ ordered TwicPics pipeline
→ final output negotiation
→ result clamp and encode
→ successful-response cache write
→ send
```

This follows the core seams already used by the inverted dialects while
retaining TwicPics' own parse and execution order.

### Pre-side-effect rejection

The following failures return before cache lookup or source fetch:

- malformed `twic` query shape or missing `v1/` prefix;
- unsupported manipulation or output;
- malformed numeric expression, unit, ratio, size, coordinate, or anchor;
- negative coordinates and invalid dimensions;
- geometry that static validation can't assemble;
- unavailable required detector;
- invalid init-time host configuration.

The phase-1 wire net uses per-arm source/cache probes so a passing status code
can't conceal an ordering regression.

### Errors

TwicPics syntax and request-shape failures preserve the current 400 text
response contract unless the support matrix records a sourced upstream error
mapping. Negative-coordinate focus is one known error-surface divergence: live
TwicPics answers 404 while ImagePipe currently answers 400. Phase 2 either maps
that case to 404 in both arms or retains 400 as an explicit accepted divergence.
Shared source, decode, input-limit, transform, output, encode, and delivery
failures use the existing core status and telemetry classification. The dialect
owns translation from its private parse errors to that observable response;
core never learns TwicPics error terms.

## Output, representation, and delivery

Output has two distinct stages. Before fetch, the dialect builds the output
policy, selects the request's negotiation branch from `Accept` and configured
capabilities, and places that selection in representation identity. It then
calls `ImagePipe.Representation.build/3`. A matching request-derived ETag can
return 304 before cache lookup, source fetch, decode, transform, or encode.

After fetch, decode, and transform provide the source format and final image,
the dialect calls `ImagePipe.Output.Negotiate.negotiate_output/4`. This stage
owns policy resolution and the deferred final-alpha probe. The caller keeps
its observable error wrapping. Clamp and encode run only after this final
resolution.

Only successful encoded responses enter the cache. Debug presentation and
content-disposition metadata ride the current request rather than a stored
entry.

## Ordered identity material

`ImagePipe.Dialect.TwicPics.Identity` owns a canonical representation of the
dialect request. It preserves step order; it must not sort the chain.

Byte-affecting identity includes:

- the ordered semantic steps and their exact operands;
- output policy and neutral encoder configuration;
- automatic orientation behavior;
- source identity and byte-identity semantics;
- detector identity when smart focus can affect output;
- the TwicPics dialect behavior epoch.

The identity partitions inputs explicitly:

- `representation` contains the ordered request, output-policy selection, and
  detector identity. It feeds both the cache key and ETag.
- `storage_only` contains configured header/cookie values that select storage
  variants. It feeds the cache key but not the ETag.
- `vary_header_names` contains configured header names plus `Accept` when
  automatic output negotiation uses it. Cookies never enter `Vary`.
- source identity is passed separately to `Representation.build/3`.
- source `byte_identity` decides whether the response receives an ETag or
  `Cache-Control: no-store`.
- delivery metadata, including the debug opt-in, enters neither digest.

The inverted config exposes `storage_inputs` as the dialect form of the
framework cache's `key_headers`/`key_cookies` behavior. The migration table in
the support matrix maps header names to `{:header, name}` and cookie names to
`{:cookie, name}`. TwicPics has no URL cachebuster today; the identity model
still reserves `storage_only` for one if the surface later adds it.

The ETag remains a request-derived byte-identity validator, not a hash of the
encoded response. Storage identity is broader than ETag identity.

Phase 1 compares legacy and dialect cache behavior with isolated caches. It
doesn't require the two stacks to produce the same internal cache-key term;
it requires equivalent storage separation, ETag behavior, Vary behavior, and
observable responses.

## Issue #457: Core chain helpers and ExDNA visibility

### Output negotiation is already core

The merged wave-2 baseline contains
`ImagePipe.Output.Negotiate.negotiate_output/4`. Framework, Native, and
imgproxy already route output policy resolution and the final-alpha leg through
it. TwicPics uses the same seam.

No extra `resolve_output/3` wrapper is introduced. Thin private wrappers
may remain only where they own a genuinely different error shape; otherwise
the caller invokes `Negotiate` directly.

### Response headers from Representation

The remaining product-neutral duplicate constructs
`ImagePipe.Response.CacheHeaders` from an
`ImagePipe.Representation`:

```elixir
%CacheHeaders{
  etag: representation.etag,
  representation_headers: vary_headers(representation.vary),
  headers: Representation.response_headers(representation)
}
```

Add:

```elixir
ImagePipe.Response.CacheHeaders.from_representation/1
```

and the Boundary dependency:

```text
ImagePipe.Response → ImagePipe.Representation
```

Response owns packaging representation identity into delivery headers;
Representation must not depend on a response struct. Native, imgproxy, and
TwicPics call the constructor, and their private `cache_headers` and
`vary_headers` copies disappear.

Focused architecture coverage pins the new one-way dependency and prevents a
reverse edge.

### Definition-level ExDNA suppression

The installed ExDNA supports Credo-style definition suppression, and its
standalone task and Credo integration use the same suppression-aware detection
pipeline:

```elixir
# ex_dna:disable-for-next-line
defp intentionally_mirrored_helper(...) do
  ...
end
```

Phase 1:

1. Removes these four paths from both global ignore lists:
   - `lib/image_pipe/dialect/native.ex`
   - `lib/image_pipe/dialect/native/pipeline.ex`
   - `lib/image_pipe/dialect/imgproxy.ex`
   - `lib/image_pipe/dialect/imgproxy/pipeline.ex`
2. Doesn't add any TwicPics dialect path.
3. Adds definition-level suppression only to irreducible structural mirrors
   that can't cross product boundaries.
4. Keeps every other definition visible to ExDNA.
5. Keeps `.credo.exs` and `mise.toml` exactly synchronized.

The four remaining whole-file exclusions retain their existing boundary
rationales until each is revisited; this inversion doesn't relabel them as
unrelated debt.

### No generic runner

The three dialects share lifecycle stages but not one observable chain:

- imgproxy owns signature and expiration gates, endpoint splitting, and
  declarative pipeline assembly;
- TwicPics owns ordered manipulations and positional focus carry;
- Native owns its grammar and `then` grouping semantics.

A shared runner would encode product ordering as callbacks or conditionals.
Neutral decisions move to core one at a time; irreducible chain control stays
inside each product and is suppressed at definition scope where ExDNA reports
the deliberate mirror.

## Differential oracle and fixture policy

### Two independent comparisons

Every differential constellation runs through both local arms and produces two
forms of evidence.

#### Each arm against TwicPics SaaS

```text
Parser.TwicPics arm ───┐
                       ├── existing pixel verdict against one committed SaaS PNG
Dialect.TwicPics arm ──┘
```

Both arms inherit the authored constellation verdict:

- `:equal` enforces the threshold and outlier budget;
- `:diverges` enforces the same two-sided monitored band;
- `:triage` remains excluded from the default lane and requires a reason and
  tracking issue.

#### Exact cross-arm comparison

```text
legacy local output ═════ new local output
```

Because both local arms use the same runtime and libvips build, SaaS tolerance
must not excuse a difference introduced by the inversion. Phase 1 requires
equal output dimensions, bands, pixels, and content type for every comparable
case. Representative deterministic responses also require raw body and
relevant header equality.

### Order discrimination

The harness passes the literal query chain to each arm. It never parses,
sorts, produces a canonical form of, or reconstructs the manipulation list. Existing pairs
such as:

```text
resize=50p/focus=50x50/crop=40x40
focus=50x50/resize=50p/crop=40x40
```

must remain different from each other while each individual chain is exact
across arms.

### Provenance and bake rules

- The inversion records one phase-base commit and freezes
  `fixtures/*.png`, `sources/*`, `manifest.exs`, and `REPORT.md` against it.
- A new constellation or source lands as a separately reviewed oracle
  prerequisite that establishes a new phase base. It never shares a commit
  with the dialect copy or a parity fix.
- A new source updates `SourceInventory` in the same change. Source bootstrap is
  a two-run workflow: `mise run twic:bake` may upload an entry whose two URLs are
  absent, but it then prints the returned `source_bytes_url` and derived
  `hosted_url` and aborts before any fixture-oracle request or manifest write.
  The engineer records both URLs in `SourceInventory` and reruns the bake.
- Every inventory entry eligible for oracle fetching must have non-empty
  `hosted_url` and `source_bytes_url`. The second bake verifies the bytes at the
  direct `source_bytes_url` against the committed source before fetching oracle
  output.
- The bake tooling gains tests proving both a missing-metadata bootstrap and an
  incomplete recorded handshake stop before any fixture request. Its current
  nil-URL success path is insufficient. The differential README documents the
  same two-run workflow.
- The incremental oracle signature remains `{chain, output suffix,
  source-byte identity}`.
- Every fixture pins `output=png`.
- `group`, `tol`, `verdict`, or `divergence` changes use
  `mix twicpics.reauthor`; they don't fetch new fixture output. `triage` needs
  no manifest refresh. Chain, source, suffix, or byte changes require a bake
  through `mise run twic:bake` (`mix twicpics.gen_fixtures`) and a new reviewed
  baseline.
- An implementation failure is fixed in code, not by re-baking.
- `:diverges` is reserved for an understood, accepted, monitored difference.
- `:triage` is reserved for an active investigation and carries a tracking
  issue.
- A structural geometry shift is never hidden by widening an `:equal`
  tolerance.

The existing skew-vs-structural diagnosis and libvips-version drift hint remain
triage aids. They don't replace the asserted pixel verdict.

### Oracle prerequisite before phase 1

Before the dialect copy begins:

1. Add live-SaaS constellations for `resize=50p/resize=340` and `resize=600`,
   using the existing grid source.
2. Confirm the shadowing output equals direct `resize=340` and differs from the
   current two-resize local result. Confirm `resize=600` stays 400×400 and is an
   ordinary `:equal` case against the current parser arm.
3. Quarantine only the shadowing case with `:triage` and a tracking issue while
   the current parser arm is knowingly wrong. Once copied, the dialect retains
   the same defect for exact cross-arm evidence. The default SaaS lane excludes
   this case until phase 2 removes the gate.
4. Update the support matrix's static-chain-collapse row from “optimization”
   to a behavioral divergence awaiting phase-2 correction. Record the plain
   resize no-enlarge characterization without claiming coverage for rejected
   conditional resize variants.
5. Correct the current differential census in both the README and support
   matrix. The matrix must name all five monitored `:diverges` cases, add the
   invisible-RGB-under-alpha note to the `inside=W:H` ratio row for its three
   canvas-under-shrink constellations, and record TwicPics' 404 versus
   ImagePipe's 400 for negative-coordinate focus.
6. Fix the hosted-source handshake gate and add its pre-oracle failure tests,
   even though both new constellations reuse an existing source.
7. Record the resulting commit as `<twicpics-phase-base>`.

From that point through phase-1 copy and phase-2 parity fixes, this command
must stay clean:

```shell
git diff --exit-code <twicpics-phase-base> -- \
  test/support/image_pipe/test/twicpics_differential/fixtures \
  test/support/image_pipe/test/twicpics_differential/sources \
  test/support/image_pipe/test/twicpics_differential/manifest.exs \
  test/support/image_pipe/test/twicpics_differential/REPORT.md
```

## Phase 1: Dialect copy and dual-run net

Phase 1 adds the inverted dialect without changing which stack serves users.
`Parser.TwicPics` remains frozen except for harness seams required to select
the two arms. This freeze ends with phase 1; phase-2 parity fixes may change both
arms under the live comparison net.

### Grammar-copy evidence

The end-to-end net is an integration gate, not the first feedback on the copy.
Phase 1 also:

- dual-runs or exact-output-compares every copied leaf grammar case from
  `manipulation_test.exs`, `output_test.exs`, `path_test.exs`, and
  `units_test.exs`, including malformed arithmetic, JSON-number grammar,
  exponents, rounding, exact ratios, path decoding, and tagged errors;
- writes dialect-local request/step and pipeline tests RED before implementing
  semantic lowering and focus carry;
- inventories every PlanBuilder, parser-wrapper, Resolver, and PointFlow test
  with a phase-2 port, move, or delete-with-citation disposition.

### Phase-1 exit gate

- Every TwicPics-specific wire case runs through both arms unless a gate is
  recorded explicitly as phase-2 debt.
- Every constellation in the recorded phase baseline runs through both arms.
- Each arm passes every default-lane SaaS verdict. A baseline `:triage` case
  runs explicitly for cross-arm evidence but isn't claimed as upstream parity.
- The local arms are exact against each other.
- Order-discriminating cases prove the harness hasn't normalized the
  chain.
- Each arm owns separate initialized config, cache, source probe, and counters.
- Telemetry assertions use a unique per-test, per-arm private
  `telemetry_prefix`; handlers attach only to that prefix and detach on cleanup.
- Representative cache-hit, cache-miss, conditional, HEAD, CORS, method,
  output-negotiation, debug, safety-limit, detector, error, and telemetry cases
  compare observable responses.
- The dependency inversion gate passes.
- The phase-base frozen-path diff is clean.
- Vale passes on changed documentation.
- A full `mise run precommit` passes.

### Recorded gates

The preferred phase-1 result is zero framework-only TwicPics gates. If a copy
can't immediately expose a framework option or delivery behavior without a
separate core decision, the gate must:

1. remain as executable framework-arm coverage;
2. be listed in a phase-2 stack-divergence backlog;
3. name the missing dialect seam;
4. have an explicit un-gate-first RED procedure.

An undocumented conditional in the harness isn't an acceptable gate.
An un-gated test that stays GREEN is a stop condition: investigate whether the
test reaches the dialect and can detect the missing behavior before continuing.

### Documentation

Phase 1 rewrites the support matrix's architectural descriptions from
Plan/Directive/Resolver language to the dialect's ordered local pipeline while
keeping behavior rows unchanged. It records any real surface, stage/order, or
pixel change in the same commit that makes the change.

The oracle prerequisite corrects the stale census and divergence descriptions
in both conformance documents. Phase 1 keeps them synchronized with the frozen
baseline without re-baking.

## Phase 2, wave 1: Close gaps under the live net

Gap closure means:

- every recorded framework-vs-dialect divergence;
- every supported-surface defect exposed by the live wire or SaaS nets;
- every config, identity, delivery, safety, or telemetry seam required for a
  host to move from the parser arm without observable regression.

It doesn't mean implementing every rejected or missing TwicPics feature.

Each gap follows this evidence sequence:

1. Remove its framework-only gate or otherwise enable the dialect assertion.
2. Run the focused test and record RED on the dialect arm.
3. Implement the fix without changing fixtures.
4. Run both arms GREEN.
5. Update the support matrix on the affected conformance axis.
6. Run the full dual-run suites before the batch commits.

The first compatibility gap is the quarantined shadowing constellation.
Remove its `:triage` gate, record RED on both local arms against the committed
SaaS fixture, implement the upstream-proven shadow rewrite in both arms, then
run it GREEN and leave it as an ordinary `:equal` case. Removing `:triage`
doesn't refresh or re-bake the manifest.

The following accepted upstream differences aren't retirement blockers by
default:

- fractional-area `cover=W:H` `resampling`;
- invisible RGB beneath transparent letterboxing under shrink;
- `focus=auto`'s unspecified upstream algorithm;
- extreme exact-rational versus IEEE-754 range behavior.

The fractional-cover and transparent-letterbox differences have pixel fixtures
with two-sided monitored bands. `focus=auto` and extreme-number range behavior
are documented divergences without equivalent pixel-lane monitoring; the
support matrix and focused wire/parser coverage own those claims. A review
must not describe an unmonitored difference as monitored.

### Wave-1 exit gate

- No framework-only TwicPics wire gates remain.
- Both arms pass every wire case.
- Both arms pass every SaaS constellation verdict.
- Exact cross-arm comparison is clean.
- The support matrix contains no stale stack-divergence statement.
- Differential fixtures remain unchanged.
- A full `mise run precommit` passes.

This unreleased library has no soak pause. The full live dual-run net is the
trust evidence for the one-way transition.

## Phase 2, wave 2: One-way retirement

Wave 2 removes the comparison arm only after wave 1's exit gate passes.

### Fixed neutral driver before transition

The current `Transform.Executor` sends neutral Plans through the same dynamic
`ImagePipe.Resolver` dispatch and measured-stage continuation protocol used by
custom strategies. Product carry can retire, but neutral resize and trim stages
still need measurement and continuation.

Before removing the TwicPics parser arm:

1. Add a fixed neutral driver beside the injected-strategy path. It calls the
   neutral lowering path directly and retains neutral staged measurement.
2. Cross-run the existing and fixed drivers over IIIF Plans and a hand-built
   product-neutral operation corpus. Compare emitted operations, measured
   continuations, final geometry/state, pixels, and error tags.
3. Route `resolver: nil` Plans and IIIF through the fixed driver while
   `Parser.TwicPics` continues through its custom strategy.
4. Run the full framework, IIIF, and TwicPics dual-run nets before proceeding.

Only dynamic host-strategy selection, product carry, carry wrapping, and the
custom strategy callback contract retire. Neutral staged execution remains.

### Coverage migration

Every reference to `Parser.TwicPics`, its Resolver, or the strategy vocabulary
is classified before deletion:

- **Port** TwicPics product behavior to dialect unit/wire coverage.
- **Move** framework-generic `ImagePipe.Plug` behavior to IIIF when IIIF can
  exercise the same contract.
- **Delete with citation** completed-transition parity tests and tests whose
  surviving dialect coverage proves the same behavior.

The inventory explicitly includes the cache-key tests and source comment that
pin resolver tags to `NeutralResolver.behavior_version/0`. After strategy
retirement, replace them with a canonical-material assertion that the removed
resolver field is absent; don't silently delete the drift assertion as an
unnoticed side effect of removing the callback.

Ported tests must demonstrate that they can fail through pre-port RED or a
temporary mutation of production behavior that the test targets. Changing only
the assertion isn't evidence. Record the failing command and output, revert the
mutation, and run GREEN. Deletions cite surviving coverage in the plan and
commit message.

### Migrate live consumers before deletion

Parser deletion waits until every live consumer has moved:

- the fiddle application mount and TwicPics web module call
  `ImagePipe.Dialect.TwicPics`; its migration passes
  `mise run precommit:fiddle` and doesn't commit `fiddle/mix.lock`;
- the differential harness selects the dialect as its surviving arm;
- `twicpics.gen_fixtures` validates a constellation through a local dialect
  parse/status seam before any hosted-oracle request, preserving the current
  pre-network typo gate;
- constellation validation tests use that dialect seam rather than
  `Parser.TwicPics`;
- bake, diagnose, report, inventory, and manifest tests contain no live parser
  dependency.

### Parser retirement

After the fixed neutral driver and all live-consumer migrations pass, cut the
TwicPics request surface to the dialect and delete the
`ImagePipe.Parser.TwicPics` tree, parser selection, docs grouping, and obsolete
test helpers. First port any lasting harness assertion to the dialect-only
suite. Then delete the legacy-arm selector, exact cross-arm comparator, and
parity-only tests. Only after those two-arm callers are gone may the shared
harness structures collapse to a single local arm. The hosted SaaS fixtures
remain the external behavioral oracle.

### Strategy SDK retirement

After the parser arm is gone, remove:

- `ImagePipe.Resolver` behaviour and wrapper;
- `ImagePipe.Plan.resolver` and its validation;
- `ImagePipe.Plan.Operation.Directive` and `Operation.directive/2`;
- `:deferred` variants on shared guide fields;
- strategy requirements in Plan validation;
- strategy module/version material in cache-key canonical encoding;
- dynamic custom-strategy dispatch, product carry wrapping, and callback
  plumbing that exists only for injected strategies;
- Boundary dependencies and exports for that SDK;
- marker-specific tests and documentation.

`Transform.NeutralResolver` or its extracted pure functions remain core
implementation details where runtime geometry needs neutral lowering. The
fixed driver retains measured-stage continuation. Retirement removes host
strategy injection, not neutral runtime geometry.

The cleanup is one-way. Don't add a compatibility adapter that reconstructs
the deleted strategy vocabulary around the dialect.

### Host parser contract after retirement

`ImagePipe.Parser` remains host-implementable, but its output contract narrows
to product-neutral declarative `ImagePipe.Plan` values. ImagePipe doesn't ship
a replacement public dialect-pipeline SDK. A host target needing ordered,
product-specific runtime carry owns a self-contained Plug and orchestration;
it must not depend on private dialect modules, `Transform.Lowering`,
`ResizePlanning`, or other in-tree implementation helpers.

`docs/custom_parser_guide.md` is rewritten accordingly:

- retain parser behavior, option validation, Plan construction, source
  references, render terminals, and testing guidance;
- remove the custom geometry strategy SDK section;
- remove `Directive` and `:deferred` vocabulary;
- state the boundary between a declarative host parser and a product-specific
  inverted Plug;
- use IIIF only for the framework features it actually demonstrates.

The retirement documentation scope also includes:

- `docs/execution_flow.md`, whose resolver dispatch, continuation wrapping,
  `:deferred`, and TwicPics strategy sections need a substantive rewrite around
  the fixed neutral driver and dialect-local pipeline;
- `docs/debug_headers.md` and `docs/cdn-http-cache.md`, whose TwicPics mount
  examples move from `parser: ImagePipe.Parser.TwicPics` to the dialect Plug.

AGENTS.md's marker-accretion guidance is updated cleanly once the last live
marker disappears. Any retained general rule must not claim a live in-tree
example that no longer exists.

### Retirement exit gate

- This negative live-surface gate passes; historical `docs/superpowers/**`
  records are excluded. This is a one-time manual exit check, not a committed
  source-scanning test; persistent enforcement belongs in the syntax-aware
  architecture-boundary tests:

  ```shell
  if rg -n \
    'Parser\.TwicPics|ImagePipe\.Resolver|Operation\.Directive|:deferred' \
    lib test fiddle AGENTS.md docs \
    --glob '!docs/superpowers/**'
  then
    echo "live TwicPics strategy references remain"
    exit 1
  fi
  ```
- The TwicPics dialect-only wire and differential suites pass.
- Framework tests pass through IIIF where moved.
- Boundary and ExDNA gates pass.
- Vale passes on changed documentation.
- `mise run precommit` passes.
- `mise run precommit:fiddle` passes.
- The support matrix describes the dialect as the sole TwicPics stack.

## Telemetry and observability

The dialect emits the same product-neutral lifecycle stage set as the other
inverted dialects through shared core seams where those exist. Product-private
request structs and step values don't enter telemetry metadata.

The phase-1 net compares:

- request result and status;
- source/fetch/decode, transform, output, encode, delivery, and send stage
  presence and nesting where observable;
- operation sequence metadata without leaking dialect structs;
- detector fallback and error classification;
- cache hit/miss and conditional outcomes.

Existing Logger and OpenTelemetry subscription surfaces are updated only if a
new product-neutral event or metadata field is introduced. Moving TwicPics to
an already-emitted event doesn't create a second event definition.

## Verification discipline

Implementation work follows these rules:

- Use `export PATH="$(mise where elixir)/bin:$PATH" && mix …` for every direct
  Mix command.
- If dependency compilation rebuilds Vix without JXL support, repair both
  environments before interpreting a JXL failure:

  ```shell
  export PATH="$(mise where elixir)/bin:$PATH" && \
    mix deps.get && \
    VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix

  export PATH="$(mise where elixir)/bin:$PATH" && \
    MIX_ENV=test mix deps.get && \
    MIX_ENV=test VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix
  ```
- Un-gate RED before implementing a parity fix.
- Prove ported tests can fail.
- Cite surviving coverage for deletions.
- Don't re-bake differential fixtures as a fix.
- Run focused tests after each batch and `mise run precommit` at each major
  checkpoint.
- Run `mise run precommit:fiddle` if the fiddle changes, building its assets
  first where required.
- Never commit `fiddle/mix.lock`.
- Review agents perform no git mutations in the shared checkout.
- Rename the branch descriptively before its first push.

## Risks and controls

### Order is normalized beyond an upstream shadow rule

**Control:** literal-chain dual-run calls plus paired order-discriminating
fixtures and wire tests. Identity tests assert that swapping two positional
steps changes canonical material. Optimizer tests admit only individually
sourced shadow rewrites and include a non-shadowing counterexample.

### SaaS tolerance hides a copy regression

**Control:** exact local arm-to-arm comparison is independent of the SaaS
verdict.

### Focus carry drifts from executed geometry

**Control:** PointFlow uses executable operations' geometry helpers, explicitly
enumerates reachable geometry-changing ops, and tests resize/crop/canvas/
orientation seams including measured resize stages.

### Preflight and execution disagree

**Control:** both derive from the validated semantic request, and focused
agreement tests compare preflight decisions with runtime assembly.

### The last in-tree consumer is mistaken for the public boundary

**Control:** the strategy SDK retirement is an explicit architectural decision,
not an unused-code inference. The custom parser contract is rewritten and
reviewed as part of the same wave.

### Strategy deletion breaks neutral measured stages

**Control:** land and cross-run the fixed neutral driver while the injected
strategy path and TwicPics parser arm still exist. Keep measurement and staged
continuation in the neutral driver; delete only product strategy injection.

### #457 creates a product runner abstraction

**Control:** only neutral decisions move to core. Irreducible product control
flow remains local and receives definition-level ExDNA suppression.

### Fixture provenance changes during the transition

**Control:** the phase-base diff keeps fixture paths, sources, hashes,
manifest, and report byte-identical. Any new constellation or authored verdict
change establishes a separately reviewed baseline rather than sharing a parity
fix commit.

## Design completion criteria

This design is ready for implementation planning when:

- the decisions table is approved;
- a compatibility reviewer has checked order, coordinate, unit, focus, and
  fixture claims against real TwicPics sources;
- an architecture reviewer has checked the dependency inversion gate, Boundary direction,
  host-parser contraction, and strategy-SDK retirement;
- a verification reviewer has checked dual-run, bake, RED-before-fix,
  coverage-port, and one-way-retirement evidence;
- accepted review findings are incorporated;
- Vale and repository documentation checks pass;
- the reviewed specification is committed.

Implementation planning starts only after explicit user approval in a later
session.

# TwicPics phase-2 retirement inventory

This inventory is the phase-1 record for the one-way retirement described in
`docs/superpowers/specs/2026-07-17-twicpics-dialect-inversion-design.md`.
This records no phase-2 edit. All paths and counts are from
`041a097572a1fbde5ca6d40961346ba6917a05ac`.

## Disposition evidence

- `PORT` names the dialect-owned destination. The row records an existing
  pre-port RED, or requires a temporary production mutation before the port is
  accepted.
- `REPOINT` names the surviving test and its replacement entry point. Phase 2
  must fail that entry point and observe the test failure before accepting the
  caller migration.
- `DELETE` names surviving matching coverage and records the unique-behavior
  analysis as `none`. The cited test already proves the behavior, so this
  disposition needs no artificial mutation.

The short acceptance labels below keep the case tables readable.

<!-- vale off -->
| Label | Required phase-2 evidence |
| --- | --- |
| `R-DIALECT` | Replace `ImagePipe.Dialect.TwicPics.call/2` with a deliberate failure at the test seam. The repointed case must fail. |
| `R-PARSE` | Replace `ImagePipe.Dialect.TwicPics.parse/2` with a deliberate tagged failure. The repointed case must fail before source, cache, or hosted-oracle work. |
| `R-PIPELINE` | Replace `ImagePipe.Dialect.TwicPics.Pipeline.run/4` with a deliberate transform failure. The repointed case must fail. |
| `R-POINT` | Break the named `ImagePipe.Dialect.TwicPics.PointFlow` entry point. The repointed case must fail at its local assertion. |
| `R-IIIF` | Replace the repointed `ImagePipe.Parser.IIIF.parse/2` call with a deliberate failure. The surviving framework case must fail. |
| `R-HARNESS` | Replace the dialect-only `Harness.plug_opts/0` or render entry point with a deliberate failure. The consumer's focused test or smoke command must fail. |
| `R-CACHE` | Remove the replacement canonical-material field/absence assertion. The focused cache-key test must fail. |
| `R-NEUTRAL` | Replace `ImagePipe.Transform.NeutralResolver.resolve_late_bound_guide/2` with a deliberate failure. The repointed neutral geometry case must fail. |
<!-- vale on -->

## Legacy parser-owned test trees

### PlanBuilder: 25 cases

All 25 cases in `test/parser/twic_pics/plan_builder_test.exs` use `DELETE`.
Their named ports already survive in
`test/image_pipe/dialect/twic_pics/request_builder_test.exs`. Task 7 recorded a
pre-port `0/25 passed` RED because `RequestBuilder.build/3` didn't exist, then
`25/25` GREEN. Unique-behavior analysis: **none** for every row.

<!-- vale off -->
| # | Legacy case | Surviving coverage |
| --- | --- | --- |
| 1 | `resize single dim -> fit auto; WxH -> stretch` | `legacy: resize single dim -> fit auto; WxH -> stretch` |
| 2 | `a folded arithmetic length builds the same plan as its literal equivalent (#325)` | Same `legacy:` case in `request_builder_test.exs` |
| 3 | `a fractional bare-pixel length rounds into the plan (#325)` | Same `legacy:` case |
| 4 | `relative-unit resize is emitted as one op per segment (no static collapse)` | Same `legacy:` case plus `quarantined relative resize shadow chain remains two literal ordered steps` |
| 5 | `focus anchor emits a positional set_focus directive and a carried cover (#321)` | `legacy: focus anchor emits a positional set_focus step and a focused cover (#321)` |
| 6 | `relative-unit coordinate focus emits set_focus directive + carried cover (#321)` | Corresponding `legacy:` request-step case |
| 7 | `bare-pixel coordinate focus emits set_focus directive + carried cover (#321)` | Corresponding `legacy:` request-step case |
| 8 | `mixed-unit coordinate focus (100x50p) parses to px + relative (#321)` | Same `legacy:` case |
| 9 | `relative focus > 1 is clamped at execution, not rejected at the parser (#321)` | Same `legacy:` case |
| 10 | `an edge focal ratio of exactly 1 (100p) emits a set_focus directive (#321)` | Same `legacy:` case |
| 11 | `focus=auto -> face-assist smart guide on the next cover` | Same `legacy:` case using `:set_auto_focus` and `{:focused, operation}` |
| 12 | `focus=auto -> face-assist smart guide on the next guided crop` | Same `legacy:` case |
| 13 | `negative focus is rejected before any fetch (#321)` | Same `legacy:` case and `parse_test.exs` pre-side-effect coverage |
| 14 | `focus=center emits a centre set_focus directive (live TwicPics accepts it)` | Same `legacy:` request-step case |
| 15 | `cover ratio -> guided ratio crop` | Same `legacy:` case |
| 16 | `cover decimal ratio reduces and flows into the guided crop` | Same `legacy:` case |
| 17 | `inside -> fit resize plus transparent canvas` | Same `legacy:` case |
| 18 | `inside ratio -> single pad-to-ratio transparent canvas` | Same `legacy:` case |
| 19 | `crop without coords carries the focus; with coords emits CropRegion (#321)` | Same `legacy:` case using `{:focused, crop}` and `{:operation, region}` |
| 20 | `output/quality last-wins, applied to Output not the pipeline` | Same `legacy:` case; it also pins `debug` last-value accumulation |
| 21 | `rejected non-goals fail the whole build` | Same `legacy:` case |
| 22 | `relative units on inside are rejected (pixel-only)` | Same `legacy:` case |
| 23 | `relative crop dimensions and zero-based coordinates build a plan` | Same `legacy:` case |
| 24 | `a region crop requires both axes explicit (omitted axis is rejected)` | Same `legacy:` case |
| 25 | `an empty pipeline still produces a valid no-op plan when only output is set` | Same `legacy:` case with an empty ordered step list |
<!-- vale on -->

### Resolver and PointFlow: 12 cases

All eight cases in `test/image_pipe/parser/twic_pics/resolver_test.exs` and all
four cases in `test/image_pipe/parser/twic_pics/point_flow_test.exs` are
`DELETE`. Task 8 wrote the 12 dialect-local ports before `Dialect.TwicPics.PointFlow`
existed. The first run failed during compilation on the missing struct. The
surviving destination is
`test/image_pipe/dialect/twic_pics/point_flow_test.exs`. Unique-behavior
analysis: **none** for every row.

<!-- vale off -->
| Legacy file | Case | Surviving coverage |
| --- | --- | --- |
| `resolver_test.exs` | `set_focus resolves the operand into the carry with zero ops` | `set_focus resolves the operand into the local carry` |
| `resolver_test.exs` | `a later set_focus overwrites the carried point` | Same-name local-carry case |
| `resolver_test.exs` | `delegated ops still match the neutral resolution for a nil point` | `an ordinary neutral operation matches the legacy resolver`; phase 2 retains the direct NeutralResolver comparison under `R-POINT` |
| `resolver_test.exs` | `a staged cover substitutes :deferred to a concrete fp and translates the carry` | `a staged cover binds a concrete point and translates the carry like legacy` |
| `resolver_test.exs` | `a nil point substitutes the centred anchor (the hot fallback path)` | `a nil point binds the centred anchor` |
| `resolver_test.exs` | `a pending-orientation cover substitutes storage-frame fp and folds reflect_rotate` | `a pending-orientation cover binds in storage and folds reflect_rotate like legacy` |
| `resolver_test.exs` | `the flush fold moves an off-centre carry` | Same-name dialect PointFlow case |
| `resolver_test.exs` | `a smart-gravity crop passes the point through unchanged` | `smart mode passes the old point through the pixel-selected crop` |
| `point_flow_test.exs` | `a known point- and dims-neutral effect passes the carried point through unchanged` | `a known point- and dims-neutral effect passes the carry unchanged` |
| `point_flow_test.exs` | `raises for a dims-changing op it has no explicit advance rule for` | `raises for an unknown dims-changing operation` |
| `point_flow_test.exs` | `raises for Trim` | Same-name dialect PointFlow case |
| `point_flow_test.exs` | `raises for Padding` | Same-name dialect PointFlow case |
<!-- vale on -->

Three surviving dialect cases still compare with `LegacyResolver`. They use
`REPOINT` under `R-POINT`. Compare an ordinary op directly with
`Transform.NeutralResolver`. Keep explicit expected operation, shape, and point
assertions for the staged-cover and pending-orientation cases. Remove only the
legacy oracle calls.

### Leaf grammar: 45 cases

The four legacy leaf files use `DELETE` after parser retirement. The dialect
copies survive at the matching paths under
`test/image_pipe/dialect/twic_pics/`. Task 6 recorded `0/48 passed` before the
five dialect leaf modules existed, followed by `48 passed`. The combined old
and new leaf gate passed `95` tests. Unique-behavior analysis: **none** for all
named cases below.

<!-- vale off -->
| Legacy file | Count | Cases | Surviving coverage |
| --- | ---: | --- | --- |
| `test/parser/twic_pics/manipulation_test.exs` | 5 | ordered `v1` segment split; required `v1`; missing `=`; stray slashes; slash inside parenthesized arithmetic | Same five cases in `dialect/twic_pics/manipulation_test.exs` |
| `test/parser/twic_pics/output_test.exs` | 2 | `auto, explicit formats, and quality`; `parse format and quality strings` | Same two cases in `dialect/twic_pics/output_test.exs` |
| `test/parser/twic_pics/path_test.exs` | 3 | source path plus chain extraction; missing `twic`; empty source path | Same three cases in `dialect/twic_pics/path_test.exs` |
| `test/parser/twic_pics/units_test.exs` | 35 | Listed in the next table | Same 35 cases in `dialect/twic_pics/units_test.exs` |
<!-- vale on -->

The 35 Units cases are:

<!-- vale off -->
1. pixels, percent, and scale;
2. reject `px` as a unit;
3. percent and scale fractions;
4. reject malformed dimensions;
5. allow zero positions;
6. zero-based coordinate origin;
7. `WxH`, single dimension, and dash-auto sizes;
8. mixed `p` and pixel units;
9. omitted crop dimension means full axis;
10. integer ratios;
11. exact reduced decimal ratios;
12. reject non-positive or malformed ratios;
13. two coordinate lengths;
14. constant-fold parenthesized arithmetic;
15. nested arithmetic and precedence;
16. reject a bare top-level operator;
17. exact arithmetic in relative units;
18. unary plus;
19. malformed arithmetic and division by zero;
20. round bare-pixel halves away from zero;
21. clamp a positive sub-pixel dimension to one;
22. reject exact zero and negative dimensions;
23. round positions while allowing zero;
24. accept well-formed JSON decimals;
25. reject leading or trailing decimal dots;
26. reject a leading zero in the integer part;
27. accept integer and decimal exponent notation;
28. keep negative exponents exact for `p`/`s` and round pixels;
29. exponent notation inside arithmetic and ratio sides;
30. exact extreme exponents, the documented IEEE-754 divergence;
31. reject malformed exponents and invalid mantissas;
32. fold arithmetic on each ratio side;
33. reject a non-positive folded ratio side;
34. map the eight anchors; and
35. reject `center` as an anchor.
<!-- vale on -->

`test/image_pipe/dialect/twic_pics/leaf_grammar_parity_test.exs` has two
phase-1-only cases and uses `DELETE` after the legacy leaf modules disappear.
The direct dialect leaf suites survive. Unique-behavior analysis: **none**.
the parity corpus is a copy-fidelity net, not a post-transition contract.

### Parser wrapper: 8 cases

Seven cases in `test/parser/twic_pics_test.exs` use `DELETE`. The `autoquality`
mount-time validation case uses `PORT`. Surviving coverage and unique-behavior
analysis are:

<!-- vale off -->
| Legacy case | Disposition | Surviving coverage or port evidence | Unique behavior |
| --- | --- | --- | --- |
| valid `parse/2` returns a request | **DELETE** | `dialect/twic_pics/parse_test.exs`: valid path composes one ordered request | none |
| unsupported transform parse error | **DELETE** | dialect parse and errors suites | none |
| `handle_error/2` sends a 400 text response | **DELETE** | `dialect/twic_pics/errors_test.exs` parse-error matrix | none |
| `validate_options!/1` resolves `:twicpics` neutral config | **DELETE** | `dialect/twic_pics/config_test.exs` flat neutral config | none |
| non-list nested `:twicpics` raises | **DELETE** | dialect config rejects nested/unknown keys | none |
| neutral quality accepted | **DELETE** | dialect config quality coverage | none |
| unknown neutral key rejected | **DELETE** | dialect config unknown-key coverage | none |
| invalid autoquality size combination raises | **PORT** | `dialect/twic_pics/config_test.exs`: `rejects size autoquality without a byte target at mount time`. Pre-port RED: expected `ArgumentError`, but nothing was raised. GREEN: `Config.validate!/1` validates the merged config through `QualitySearch.from_config/1`. Removing that validation produced the same RED (`9/10 passed`). |
<!-- vale on -->

## Wire and differential nets

### Original 49 wire cases

The pre-phase file at `bdb421ab^` has exactly 49 `test` declarations. Each uses
`REPOINT` in the same
`test/image_pipe/twic_pics_wire_conformance_test.exs` body to the sole dialect
entry point under `R-DIALECT`. Only the generated framework module and option
translator retire. Task 11's deliberate dialect-500 mutation failed exactly
the 49 dialect copies while all 49 framework copies stayed green.

The 49 cases are:

<!-- vale off -->
1. auto-orientation without geometry;
2. chained resize uses the upright frame;
3. single resize reaches the intermediate dimension;
4. parenthesized arithmetic equals its literal;
5. fractional bare-pixel rounding;
6. JSON exponent equals its literal;
7. chained relative resize uses running dimensions;
8. three-hop relative resize compounds;
9. bare percent uses source width;
10. malformed chain fails before fetch;
11. anchor focus steers cover;
12. relative-coordinate focus steers cover;
13. bare-pixel focus steers cover;
14. relative focus above one clamps;
15. negative focus fails before fetch;
16. focus resolves at its chain position;
17. mixed-unit focus resolves per axis;
18. focus survives contain into crop;
19. focus steers a second consumer;
20. region crop carries focus without reset;
21. out-of-bounds region origin clamps;
22. automatic focus steers cover;
23. `focus=center` is accepted;
24. focus resolves in the EXIF display frame;
25. ratio cover crops without scaling;
26. contain versus inside geometry;
27. non-alpha inside output flattens;
28. inside ratio pads rather than crops;
29. zero-based region crop origin;
30. relative crop dimensions use running dimensions;
31. relative crop coordinates equal pixel coordinates;
32. zero crop dimension fails before fetch;
33. relative inside units remain rejected;
34. explicit output bypasses negotiation and auto emits `Vary`;
35. oversized chained upscale clamps after fetch;
36. equivalent requests reuse a cache entry;
37. `debug=1` emits headers when allowed;
38. no debug headers without the segment;
39. no debug headers when the host switch is off;
40. `debug=0` opts out;
41. invalid debug is a 400;
42. configured quality applies when URL quality is absent;
43. URL quality overrides configured quality;
44. host JPEG options reach the request;
45. EXIF focus carries through cover to a post-flush consumer;
46. EXIF focus carries through a region crop;
47. focus carries through two covers;
48. nil-point center fallback under EXIF quarter-turn; and
49. focus carries through an inside canvas embed.
<!-- vale on -->

### Added lifecycle and cross-arm wire cases

The ten shared lifecycle cases use `REPOINT` with the original 49 under
`R-DIALECT`. They cover HEAD, methods, CORS, a strong early 304, cache behavior,
storage identity, detector identity, the input pixel limit, and private
telemetry prefixes.

The nine tests in the `CrossArm` module use `DELETE` after framework retirement.
They comprise one ETag-classifier helper test and eight comparisons for
explicit PNG, explicit JPEG, automatic WebP, parse error, conditional 304,
HEAD, cache hit, and debug. The surviving dialect-only 59-case body plus contract,
lifecycle, and error-path suites cover every behavior. Unique-behavior
analysis: **none**. Literal cross-arm comparison has no meaning with one arm.

### SaaS and exact local comparison

<!-- vale off -->
| File/cases | Disposition | Destination and evidence |
| --- | --- | --- |
| `test/image_pipe/twicpics_differential_conformance_test.exs`: 39 authored constellations × 2 arms, 38 default per arm plus one triage per arm | **REPOINT** | Collapse to one dialect render per authored constellation through `Harness.plug_opts/0`; `R-HARNESS`. Keep all five monitored divergence bands and the quarantined shadow verdict unchanged. |
| `test/image_pipe/twicpics_cross_arm_conformance_test.exs`: 39 exact cases plus one order self-check | **DELETE** | Surviving dialect SaaS lane, wire order case, RequestBuilder ordering, and Pipeline ordering. Unique behavior: none after transition. |
| `test/support/image_pipe/test/twicpics_differential/harness.ex` | **REPOINT** | `plug_opts/0` initializes `ImagePipe.Dialect.TwicPics`; remove the arm selector only after dual callers are gone. `R-HARNESS`. |
<!-- vale on -->

Task 12 proved `78 passed, 2 excluded` in the dual SaaS file and `39` exact
local cases plus the order self-check. An order mutation made the affected
exact comparison and the dialect order self-check fail.

## Remaining test references

### Framework-generic Plug coverage

The following 22 cases in `test/image_pipe/plug_test.exs` use `REPOINT` to
`ImagePipe.Parser.IIIF` under `R-IIIF`. They contain 23 TwicPics-parser
references because the matching-`Accept` case mounts the parser twice. They
test `ImagePipe.Plug`, cache, source, negotiation, materialization, or delivery
behavior rather than a TwicPics product rule:

<!-- vale off -->
1. automatic source-format output needs no encoder override;
2. cache hit without origin fetch;
3. automatic-output miss stores `Vary` and content type;
4. matching raw `Accept` headers normalize at the cache boundary;
5. cache-miss stream encode failures are not cached and preserve `Vary`;
6. automatic output negotiates from `Accept` and sets `Vary`;
7. missing, empty, and wildcard-only `Accept` use source format;
8. automatic fallback selects accepted source format;
9. server preference outranks relative q-values;
10. exact `q=0` beats `image/*`;
11. automatic AVIF cache hit skips origin;
12. automatic JPEG source-format cache hit skips origin;
13. deferred source-format hit can serve disabled modern formats;
14. automatic key exists before fetch with modern formats disabled;
15. disabled modern formats still set `Vary`;
16. disabled modern formats use source output despite baseline exclusions;
17. source-format negotiation ignores baseline `Accept`;
18. source-format decode failure cancels the stream;
19. source format is used when baseline formats are excluded;
20. sequential materialization failure maps to decode error;
21. deferred automatic materialization failure maps to decode error; and
22. automatic cache-write failure fails open and preserves `Vary`.
<!-- vale on -->

Both parser mounts in the matching-`Accept` case move together under the
same `R-IIIF` acceptance mutation.

The 20 cases in `test/image_pipe/cdn_http_cache_wire_test.exs` split as follows:

- The first 19 cases are **REPOINT** to `ImagePipe.Parser.IIIF` under `R-IIIF`:
  public cache headers, concrete and wildcard conditional behavior, HEAD,
  `Vary`, request/response cookies, hit freshness, CORS, content disposition,
  detector identity, cache-sink fail-open delivery, and guide-bearing focal
  gravity.
- `TwicPics carried-focus cover emits an etag on the strong-identity path` is
  `DELETE`. The dialect wire life cycle, strong ETag, detector identity, and
  focus cases plus `TwicPicsContractTest` survive. Unique behavior: none.

The `test/image_pipe/request_safety_test.exs` case `invalid composition parser
failures return before source identity, cache lookup, and origin` is
`REPOINT` to an invalid IIIF request under `R-IIIF`.

### Dialect tests with temporary legacy or framework oracles

<!-- vale off -->
| File/cases | Disposition | Replacement and acceptance |
| --- | --- | --- |
| `dialect/twic_pics/pipeline_test.exs`: focus/multiple-consumer pixels; auto-focus then region crop; pending EXIF flush; detector modes | **REPOINT** | Keep the local Pipeline assertions, frozen expected pixels/event sequences, and dialect wire/differential citations; remove `PlanBuilder` and `Transform.execute_plan/3`. `R-PIPELINE`. |
| `dialect/twic_pics/point_flow_test.exs`: ordinary neutral op; staged cover; pending-orientation cover | **REPOINT** | Direct NeutralResolver or explicit expected operation/shape/point assertions; remove `LegacyResolver`. `R-POINT`. |
| `dialect/twic_pics/request_builder_test.exs` and `request_test.exs`: forbidden-vocabulary anti-tautology fixtures for `Parser.TwicPics.Resolver`, a `resolver` map field, and `Operation.Directive` traversal | **DELETE** | Keep the positive recursive scan over every produced request. Delete the retiring module atoms, synthetic resolver field, and Directive-only traversal clauses. Unique behavior: none. |
| `test/image_pipe/transform/focus_test.exs`: seven `plan_cell/1` cases, their explicit `Parser.TwicPics.Resolver` fixture, and the 16-cell pending-orientation matrix | **DELETE** | Dialect PointFlow, Pipeline, wire focus/carry, and EXIF cases survive. Product-neutral rational helper tests remain. Unique behavior: none. |
<!-- vale on -->

### Telemetry and architecture

The six arm-comparison scenarios in
`test/image_pipe/twic_pics_telemetry_contract_test.exs` are **REPOINT** to
dialect-only semantic expectations under `R-DIALECT`: cache miss, cache hit,
304, parse error, streamed failure, and owner cancellation. Keep each unique
per-test private prefix and cleanup. The three pure semantic-normalization
tests survive unchanged. Remove only framework option construction and
arm-comparison helpers.

The `ImagePipe.Parser.TwicPics` entry in
`test/image_pipe/architecture_boundary_test.exs` and the corresponding parser
boundary assertion uses `DELETE`. The IIIF parser boundary and the dialect's
exact dependency/no-export plus no-framework-reference gates survive. Unique
behavior: none.

### Cache key and strategy-version pins

<!-- vale off -->
| Current case or source | Disposition | Replacement and acceptance |
| --- | --- | --- |
| `cache/key_test.exs`: three `TwicPics carried focus (#321)` cases | **DELETE** | Dialect `Identity.material/5`, contract cache-key tests, and wire storage-identity tests survive. Unique behavior: none. |
| `cache/key_test.exs`: nil resolver tags neutral strategy | **REPOINT** | Assert the post-retirement canonical plan material contains no resolver field. `R-CACHE`. |
| `cache/key_test.exs`: explicit neutral strategy module/version | **REPOINT** | Same absence assertion; the injected strategy surface is removed. `R-CACHE`. |
| `cache/key_test.exs`: TwicPics resolver module/version | **REPOINT** | Same absence assertion; dialect identity is owned by `Dialect.TwicPics.Identity`. `R-CACHE`. |
| `lib/image_pipe/cache/key.ex` comment and `resolver_data/1` | **DELETE** | The replacement absence test above is the drift guard. Unique behavior: none after the resolver field and callback retire. |
<!-- vale on -->

### Strategy and marker SDK surface

Phase 2 removes the shared strategy SDK and marker vocabulary only after the
dialect callers retire. These rows prevent tests, types, cache material, or
comments from surviving as an accidental public contract.

<!-- vale off -->
| Current file or cases | Disposition | Destination and required evidence |
| --- | --- | --- |
| `lib/image_pipe/parser.ex`: `ImagePipe.Resolver` Boundary dependency | **DELETE** | Keep Parser's Config, Format, Plan, Renderer, and Transform dependencies and zero exports. The exact parser Boundary assertion must pin that remaining set. Unique behavior: none after the last compatibility strategy retires. |
| `lib/image_pipe/transform.ex`: `ImagePipe.Resolver` Boundary dependency, strategy-SDK export rationale, and strategy comments | **REPOINT** | Remove the Resolver dependency and strategy-SDK framing. Retain only exports required by the fixed neutral driver and dialect-owned pipelines, with exact dependency/export assertions. Product-neutral `SourceShape`, neutral lowering, and executable operations remain only when a live caller proves them. |
| `test/image_pipe/plan_test.exs`: missing-resolver cases for deferred resize, deferred crop, and Directive | **DELETE** | The dialect Request forbidden-vocabulary tests and post-retirement Plan validation suite survive. Unique behavior: none after Plan no longer accepts strategy-only vocabulary. |
| `test/image_pipe/plan_test.exs`: smart/detect guide and `:auto` resize cases phrased as valid “without a resolver” | **REPOINT** | Keep their product-neutral Plan validation assertions, remove resolver contrast and strategy vocabulary, and deliberately break the corresponding Plan validation branch to prove the rewritten cases remain load-bearing. |
| `test/image_pipe/plan_test.exs`: non-module resolver rejection plus nil/module resolver acceptance | **DELETE** | Replace them with the syntax-aware root-Plan resolver-absence gate below. Unique behavior: none after the field leaves the root Plan. |
| `test/image_pipe/plan/operation_test.exs`: Directive constructor plus deferred resize/crop constructor acceptance | **DELETE** | The constructor suites for concrete anchors, focal guides, and smart guides survive. Unique behavior: none after Directive and `:deferred` leave the constructor surface. |
| `test/image_pipe/plan/key_data_test.exs`: `Operation.directive/2` key material | **DELETE** | Concrete operation key-data cases and the root-Plan resolver-absence assertion survive. Unique behavior: none after Directive becomes unconstructable. |
| `test/image_pipe/request_runner_test.exs`: semantic cache-miss case with an explicit root Plan `NeutralResolver` | **REPOINT** | Remove the resolver field while retaining the cache-before-fetch, fixed neutral execution, stream, and cache-write assertions. A deliberate failure of the fixed transform entry point must fail this case. |
| `test/image_pipe/resolver_test.exs`: four facade dispatch/continuation/rewrap cases | **DELETE** | Dialect Pipeline/PointFlow and direct NeutralResolver suites survive. Unique behavior: none after the `ImagePipe.Resolver` facade retires. |
| `test/image_pipe/transform/executor_test.exs`: injected `Probe` strategy and pipeline-loop measurement case | **DELETE** | Product-neutral executor transform tests and dialect Pipeline order/measurement tests survive. Unique behavior: none after Executor loses injected strategy dispatch. |
| `test/image_pipe/transform/resolved_plan_golden_test.exs`: four injected `{NeutralResolver, NeutralResolver.init()}` driver fixtures | **REPOINT** | Drive the fixed neutral executor without an injected strategy tuple. Keep the identity-streaming, acquired-dimension, staged-continuation, and orientation assertions; a fixed-driver mutation must fail their golden expectations. |
| `test/image_pipe/transform/neutral_resolver_test.exs`: deferred-oracle comparisons in the two late-bound-guide cases | **REPOINT** | Keep direct expected executable, continuation, rectangle, and odd-pixel assertions through `NeutralResolver.resolve_late_bound_guide/2`; remove only the `:deferred` oracle arm. `R-NEUTRAL`. |
| `test/image_pipe/architecture_boundary_test.exs`: Resolver Boundary dependency/export assertion | **DELETE** | Keep exact Parser and Transform Boundary assertions for the post-retirement dependency graph. Unique behavior: none after the Resolver boundary retires. |
| `test/image_pipe/architecture_boundary_test.exs`: Plan export of `Operation.Directive` | **DELETE** | Keep the exact Plan dependency/export assertion without Directive. Unique behavior: none after the module retires. |
| `test/image_pipe/architecture_boundary_test.exs`: parser executable-operation scan's resolver-strategy file exception | **REPOINT** | Keep the parser semantic-operation boundary scan and remove the exception set. A concrete transform reference injected into a surviving parser must fail the scan. |
| `test/image_pipe/architecture_boundary_test.exs`: carried-strategy execution-state isolation assertion | **DELETE** | Fixed neutral-driver and dialect boundary assertions survive. Unique behavior: none after no carried strategy file remains. |
| `test/image_pipe/cache/key_test.exs`: resolver material/version assertions | **REPOINT** | Assert canonical Plan material contains no resolver field. `R-CACHE`. |
| `lib/image_pipe/plan.ex`: resolver field, strategy initialization, and `requires_strategy?` checks | **DELETE** | Plan construction and validation tests for product-neutral operations survive. Unique behavior: none after parser retirement. |
| `lib/image_pipe/plan/operation.ex`, `plan/operation/directive.ex`, `plan/operation/resize.ex`, and `plan/operation/crop_guided.ex`: Directive and deferred-guide constructors/types | **DELETE** | Dialect Request steps and PointFlow own positional focus. Product-neutral operation constructor tests survive without marker cases. Unique behavior: none. |
| `lib/image_pipe/plan/key_data.ex`: Directive material and deferred guide material | **DELETE** | Concrete operation key-data tests and the resolver-field absence assertion survive. Unique behavior: none after those values become unconstructable. |
| `lib/image_pipe/cache/key.ex`: `resolver_data/1` and strategy-version material | **DELETE** | The replacement absence assertion is the drift guard. Unique behavior: none. |
| `lib/image_pipe/resolver.ex` | **DELETE** | Direct neutral lowering and each dialect-owned pipeline replace the behavior, facade, continuation state, rewrap helper, and `behavior_version/0`. Unique behavior: none after all callers migrate. |
| `lib/image_pipe/transform/executor.ex`: injected strategy loop and transitional continuation types | **REPOINT** | Keep fixed neutral execution through the generic transform entry point. A deliberate failure of that entry point must fail the surviving executor transform suite. |
| `lib/image_pipe/transform/neutral_resolver.ex`: Resolver behavior callbacks, strategy version, and transitional Resolver continuation types | **REPOINT** | Keep direct product-neutral lowering and late-bound-guide functions; remove behavior callbacks and return types tied to `ImagePipe.Resolver`. `R-NEUTRAL`. |
| `lib/image_pipe/transform/lowering.ex` and `transform/operation/crop.ex`: deferred marker translation/types | **DELETE** | Concrete late-bound gravity and direct PointFlow binding survive. Unique behavior: none after no producer emits the marker. |
| `lib/image_pipe/transform/focus.ex`: legacy TwicPics PointFlow comment | **DELETE** | Keep the neutral point math and its unit tests. Unique behavior: none; this is a stale production comment. |
| `lib/image_pipe/response/error_status.ex`: `:strategy_required` plan-validation status tag | **DELETE** | The generic plan-validation 422 assertion in `response/error_status_test.exs` and the qualified Phase-2 negative gate survive. Unique behavior: none after Plan can no longer emit the tag. |
| `lib/image_pipe/transform/resize_planning.ex`: “not part of the strategy SDK” export-tier comment | **DELETE** | Exact Transform Boundary exports and the neutral/native/imgproxy resize paths remain the executable evidence. Unique behavior: none; only the retired SDK comparison disappears. |
| `lib/image_pipe/dialect/native/pipeline.ex` and `lib/image_pipe/dialect/imgproxy/pipeline.ex`: framework-strategy comparison and carry comments | **REPOINT** | Keep the observable group/pipeline scoping and fixed neutral-driver behavior. Rewrite comments without the retired Resolver, strategy initialization, or framework comparison vocabulary. |
| `test/support/image_pipe/ordered_spike/pipeline.ex`: anti-strategy comparison in the probe module documentation | **REPOINT** | Keep the measured left-to-right interpreter contract and probe tests. Remove only the contrast with the retired strategy framework. |
| `test/image_pipe/plan/vendor_mapping_fixture_test.exs`: two `:strategy_guide` fixtures and notes | **REPOINT** | Use concrete product-neutral smart/guided-crop vocabulary while retaining the vendor identities and classification census. Deliberately corrupt the rewritten fixture and observe the shallow-fixture test fail. |
| `lib/image_pipe/dialect/imgproxy/config.ex`: Parser.TwicPics widening comment | **DELETE** | `ImagePipe.Config.keys/0` remains covered by direct config tests. Unique behavior: none; this is a stale production comment. |
| `AGENTS.md`, `docs/custom_parser_guide.md`, and `docs/execution_flow.md`: live strategy, marker, Directive, and behavior-version guidance | **DELETE** or **REPOINT** | Remove TwicPics-specific marker guidance. Rewrite remaining product-neutral guidance for the fixed neutral driver and self-contained dialect Plugs. Documentation Vale must pass. |
<!-- vale on -->

Phase 2 must finish with this qualified live-surface negative gate returning no
matches:

```shell
rg -n 'ImagePipe\.Resolver|ImagePipe\.Parser\.TwicPics|TwicPics\.Resolver|LegacyResolver|behavior_version|resolver_data|Operation\.(Directive|directive)|:strategy_required|:deferred|strategy SDK|carried resolver strategy' \
  lib test fiddle docs AGENTS.md \
  --glob '!docs/superpowers/**'
```

Phase 2 must also add a syntax-aware architecture test for the root
`ImagePipe.Plan`. Parse the live Elixir AST and resolve module name bindings.
Reject a `:resolver` root-struct field or type. Also reject root-Plan
construction or updates with a resolver key and field reads from a binding
established as a root Plan. The test must not flag the unrelated IIIF source
resolver, HTTP `address_resolver`, telemetry resolver, or other host-option
groups. This AST gate replaces the impossible broad search for every
`resolver:` token.

Any qualified match that intentionally survives needs a named replacement
contract in the Phase-2 closeout. Historical design records remain excluded.

## Live consumers and support tools

<!-- vale off -->
| Consumer | Disposition | Replacement entry point and phase-2 acceptance |
| --- | --- | --- |
| `fiddle/lib/image_pipe_fiddle/application.ex` TwicPics mount | **REPOINT** | Mount `ImagePipe.Dialect.TwicPics` directly with flat options; `R-DIALECT` plus `mise run precommit:fiddle`; `fiddle/mix.lock` must remain unchanged. |
| `fiddle/lib/image_pipe_fiddle_web/twic_pics.ex` request dispatch | **REPOINT** | Call `ImagePipe.Dialect.TwicPics.call/2` instead of `ImagePipe.Plug.call/2`; `R-DIALECT` plus `mise run precommit:fiddle`. |
| `test/support/mix/tasks/twicpics.gen_fixtures.ex` pre-network parse gate | **REPOINT** | `Dialect.TwicPics.Config.validate!/1` and `Dialect.TwicPics.parse/2`; `R-PARSE` must abort before any hosted-oracle request or write. |
| `test/image_pipe/twicpics_differential/constellations_test.exs` non-triaged parse gate | **REPOINT** | Dialect `parse/2`; `R-PARSE`. Keep the authored 39-case verdict/quarantine census. |
| `Mix.Tasks.Twicpics.Diagnose` | **REPOINT** | Dialect-only `Harness.plug_opts/0`; `R-HARNESS`, proven with a focused no-network diagnose command. |
| `Mix.Tasks.Twicpics.GenReport` and the tagged smoke test | **REPOINT** | Dialect-only `Harness.plug_opts/0`; `R-HARNESS`; the smoke must still render all 39 cards. |
| `Mix.Tasks.Twicpics.Reauthor` | **REPOINT** | Retain its data-only `Constellations`/`Manifest` entry points; deliberately fail `Manifest.load!/1` and observe the task fail. It has no parser dependency now. |
| `gen_fixtures_test.exs` and `source_hosting_test.exs` | **REPOINT** | Retain injected `GenFixtures.run_with/2` and `SourceHosting.resolve!/3`; deliberately fail the selected entry point and observe the focused case fail. The production parse gate is covered separately above. |
| `manifest_test.exs` | **REPOINT** | Retain `Manifest.load!/1`, `write!/2`, `fresh?/3`, and digest tests; a deliberate `Manifest.load!/1` failure must fail the round-trip case. It has no parser dependency now. |
| `twicpics_source_inventory_test.exs` | **REPOINT** | Retain `SourceInventory.all/0` and byte-fact drift checks; a deliberate empty inventory must fail the drift census. It has no parser dependency now. |
<!-- vale on -->

The fixture PNG files, source images, `manifest.exs`, and `REPORT.md` are oracle
data, not retirement targets. They must remain byte-unchanged.

## Documentation references

<!-- vale off -->
| Live document | Disposition | Required result |
| --- | --- | --- |
| `docs/twicpics_support_matrix.md` | **REPOINT** | Describe the dialect as the serving stack after wave 2; remove the temporary comparison-arm wording only then. |
| `docs/custom_parser_guide.md` | **REPOINT** | Keep host parser/Plan guidance; remove the strategy SDK, Directive, marker, TwicPics Resolver/PointFlow template, and `behavior_version/0` cache section. Explain that ordered product runtime carry requires a self-contained Plug. |
| `docs/execution_flow.md` | **REPOINT** | Replace TwicPics parser/resolver dispatch with the fixed neutral driver and dialect-local pipeline. |
| `docs/cdn-http-cache.md` | **REPOINT** | Replace the TwicPics parser mount example with the dialect Plug or use IIIF for framework-only configuration. |
| `docs/debug_headers.md` | **REPOINT** | Replace the TwicPics parser mount example with the dialect Plug and retain the TwicPics `debug=1` behavior. |
| `AGENTS.md` marker-accretion example | **DELETE** | Remove the retired live TwicPics marker example cleanly. Any retained general rule must not claim a live marker. Unique behavior: none. |
<!-- vale on -->

Historical `docs/superpowers/**` files are immutable design/implementation
records. They contain Parser/Resolver vocabulary but aren't live retirement
surface. The spec's negative exit gate excludes them. The broad census counts
them, but phase 2 won't rewrite or delete them.

## Completeness commands and census

These commands define the reviewable census at the phase-1 closeout:

```shell
rg --files test/parser/twic_pics test/image_pipe/parser/twic_pics | sort
rg -n '^\s*(test|property)\s+"' \
  test/parser/twic_pics/*.exs \
  test/image_pipe/parser/twic_pics/*.exs
rg -n 'ImagePipe\.Parser\.TwicPics|Parser\.TwicPics|TwicPics\.Resolver|TwicPics\.PointFlow' \
  test fiddle docs lib test/support/mix/tasks \
  --glob '!docs/superpowers/**'
rg -n 'behavior_version|resolver_data|:resolver|Operation\.Directive|:deferred' \
  test/image_pipe/cache/key_test.exs lib/image_pipe/cache/key.ex \
  docs/custom_parser_guide.md docs/execution_flow.md AGENTS.md
```

Observed counts:

- parser-owned target trees: seven files, 82 cases;
- PlanBuilder: 25;
- Resolver plus PointFlow: 12 (`8 + 4`);
- leaf grammar: 45 (`5 + 35 + 2 + 3`);
- parser wrapper outside those trees: eight;
- original wire body: 49;
- current shared lifecycle additions: ten;
- current cross-arm wire helper/comparators: nine;
- authored SaaS constellations: 39, with 38 default and one triage per arm;
- exact local constellation comparisons: 39, plus one order self-check;
- generic Plug cases using the TwicPics parser: 22 cases, 23 references;
- CDN cache cases: 20, of which one is TwicPics-specific;
- current supported verdicts: 34 `:equal`, five `:diverges`, one `:triage`.

The broad search also returns historical `docs/superpowers/**` records. Review
must compare the live-surface search with and without that exclusion rather
than treating historical records as missed retirement work.

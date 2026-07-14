# Dialect-owned pipelines — probe report

Deliverable of the *dialect-owned pipelines* probe
([spec](../specs/2026-07-13-dialect-owned-pipelines-design.md),
[plan](../plans/2026-07-13-dialect-owned-pipelines-probe.md)). It measures the
inverted `ImagePipe.Dialect.Native` stack against the framework
(`ImagePipe.Plug` + `Request`/`Resolver`/`Renderer`) stack that continues to
serve imgproxy, IIIF and TwicPics untouched.

**Honesty contract.** Every number below is read from a task report's
measured/test-backed result or traced from the code as built. Where a bound
could not be established, or a criterion is only partially satisfied, that is
recorded as an explicit gap — never smoothed over. The report's value is its
honesty, not its optimism.

**Transitional scope (stated up front).** Per Task 14's deliberately limited
geometry scope ([spec §Task 14], Decision 11), the native path **removes** the
`Resolver` facade, strategy selection/registration, `Directive`, deferred
markers, and `%Plan{}`/`Plan.Pipeline`, but **deliberately retains** the
semantic `Plan.Operation` structs, `SourceShape`, the `{ops, continuation}`
vocabulary, and the neutral lowering (`NeutralResolver`) as a core geometry
compiler. The probe therefore validates *dialect-owned request orchestration
over a retained neutral geometry compiler*; it does **not** demonstrate that the
operation mirror or the continuation vocabulary can die. Section 7 assesses what
their death would require. This report does not claim the operation mirror
collapsed.

---

## 1. Hop-count / concept-count comparison

Same logical request through both stacks, cache-miss image path:

- Framework: imgproxy `/rs:fill:800:0/plain/…/cat.jpg` (equivalently the
  `/w=800` intent) → `ImagePipe.Plug`.
- Native: `/w=800/src/images/cat.jpg` → `ImagePipe.Dialect.Native`.

Baseline is `docs/execution_flow.md`'s call spine (**~14 hops / ~8 concept
families**). Both are *counted from the code as built*, not estimated.

### 1a. Framework hops (from `docs/execution_flow.md` "The call spine")

1. `Plug.call` → `parser.parse` (dynamic dispatch ①: Imgproxy parser →
   `PlanBuilder` → `%Plan{}`)
2. `Plug` → Plan validation (prefetch-safe shape checks)
3. `Plug` → `Source.resolve` (source identity, no bytes)
4. `Plug` → HTTP conditional check (ETag → 304 before fetch)
5. `Plug` → `Request.Runner.run`
6. `Runner` → cache lookup
7. `Runner` (miss) → `Request.Processor`
8. `Processor` → fetch (`Source.fetch`)
9. `Processor` → format gate
10. `Processor` → decode (sequential, shrink-on-load) via `DecodePlanner`
11. `Processor` → safety limits (`max_input_pixels`)
12. `Processor` → `Transform.execute_plan` → `Transform.Executor.execute`
    (seed EXIF orientation + input color management; seed `SourceShape` +
    strategy state)
13. `Executor.run` resolve loop: overlay → `Resolver.resolve` (dispatch ②) →
    `Chain.execute` (dispatch ③) → continuation (dispatch ④ measure →
    strategy `continue`) → `Flush` at boundary
14. `Processor` → encode (lazy) → `Producer`/`PreparedStream` →
    `Response.Sender` + incremental cache write

**Dynamic-dispatch seams ("go to definition stops working"), from the
execution-flow table:** `parser.parse` ①, `Resolver.resolve` ②, `chain` ③,
`Resolver.continue` ④, and `render` — **5 seams**. Orchestration is spread
across **3 top-level orchestrators** (`Plug`, `Request.Runner`,
`Request.Processor`) plus the `Executor` resolve loop.

### 1b. Native hops (traced from `lib/image_pipe/dialect/native.ex` as built)

`call/2` → `route/2` is one linear `with` chain in a single module; the numbered
transitions are the calls it makes out to collaborators:

1. `route` → `Native.Path.split_signature` + `Native.Signature.verify` (403
   before any parse; `[:parse]` span)
2. `route` → `Native.Path.extract` (full lex) → `Native.Parser.parse` →
   `%Native.Request{}`
3. `route` → `check_expires` (`Native.Signature.expired?`, 404 gate)
4. `route` → `Native.Source.translate` → `%Plan.Source{}`
5. `route` → `ImagePipe.Source.resolve` → `%Source.Resolved{}` (identity, no
   bytes)
6. `route` → `negotiate` → `Identity.plan_output` + `Output.Policy`
   (`from_output_plan` / `ensure_capable` / `identity_selection` /
   `identity_material`)
7. `route` → `Representation.build` (+ `Identity.material`) → key/ETag/Vary
8. `route` → `Response.Conditional.not_modified?` (ETag → 304 before fetch)
9. `route` → `serve` → `Cache.lookup_entry`
10. `serve` (miss) → `generate` → `build_fun` + `Native.Delivery.stream`
    (→ `Coordinator` → `Producer`)
11. inside the producer, `build_fun` → `Decode.with_image`: `Source.with_fetched`
    (fetch) + `Decode.SourceFormat` (format gate) + header open +
    `max_input_pixels` + `Pipeline.decode_request` →
    `DecodePlanner.open_options_for` + sequential re-open + seed
    `%Transform.State{}` + `%SourceGeometry{}`
12. `build_and_pump` → `Pipeline.run` → `group_operations` →
    `NeutralResolver.resolve`/`continue` (geometry compiler, called as plain
    stateless functions) → `Chain.execute`
13. → `resolve_output` (`Policy.resolve`)
14. → `Output.Clamp.clamp`
15. → `Output.Encoder.stream_output`
16. → `pump.(stream, …)` → `Producer` → `Coordinator` → `Response.Sender`
    (chunked) + incremental cache-sink write

**Dynamic-dispatch seams:** `NeutralResolver` is called as a *direct, static*
function (no `Resolver` facade, no strategy selection/registration/`rewrap`);
`Chain.execute` is a direct call (the `:chain`/`:measure_dims`/`:continue`
injectables are test-only seams, never set by real callers — Task 15);
`Native.Parser.parse` is a direct static call (no `parser.parse` module
dispatch); there is no `render` dispatch in the probe subset (the image path
streams directly; the BlurHash terminal is dialect-owned inline). **≈1 residual
seam** (`Cache`/`Source` adapters remain host-pluggable, as in both stacks).

### 1c. Honest totals

| Measure | Framework (baseline) | Native (as built) |
|---|---|---|
| Raw module-transition hops | ~14 | **~16** (traced above) |
| Dynamic-dispatch "go-to-def stops" seams | 5 (①②③④ + render) | **~1** |
| Top-level orchestrators to read | 3 (`Plug`, `Runner`, `Processor`) + `Executor` loop | **1** (`native.ex` `route`→`serve`→`generate`) |

**The followability headline, counted honestly: raw hop count did NOT shrink**
(native is ~16 vs the ~14 baseline — comparable, marginally more collaborators
called). The win is not fewer transitions; it is (a) collapsing the
**dynamic-dispatch seams from 5 to ~1**, and (b) concentrating orchestration
into **one module read top-to-bottom** (`route`/`serve`/`generate`) instead of
three orchestrators plus a resolve loop. You can `Ctrl-click` the native chain
end to end; the framework chain forces four detours through facade/strategy
dispatch.

### 1d. Concept families — counted honestly (retained vs removed)

Baseline ~8 families (execution_flow "two operation vocabularies" + resolve
loop + plumbing). The native geometry path **RETAINS** four of them verbatim —
this is Task 14's transitional scope, not a collapse:

- **`Plan.Operation.*`** (declarative semantic structs) — retained; the parser
  emits them, `group_operations` feeds them to the compiler.
- **`Transform.Operation.*`** (executable, lowered) — retained; what
  `Chain.execute` runs.
- **`SourceShape`** (pure geometry value: dims, frame, pending orientation,
  decode shrink) — retained; seeded once, flushed once (`pipeline.ex`).
- **`{ops, continuation}` vocabulary + measure tags** — retained;
  `NeutralResolver.resolve/3` + `continue/4` + the depth-capped `follow/5`
  driver still speak `{:advance, …}` / `{:measure, tag, …}`.

The native path **REMOVES** these families relative to the framework:

- The **`Resolver` facade** + strategy selection/registration + `rewrap`
  (native calls `NeutralResolver` directly as a stateless toolkit function).
- **`Directive`** and the deferred **`{:effective, …}` markers** (native
  resolves `:auto` before packing the `DecodePlanner.Request`).
- **`%Plan{}` / `Plan.Pipeline`** (native uses `%Native.Request{}` + `Group`).
- **`render` dispatch** (no custom renderer in the probe subset).
- The **`Runner`/`Processor` orchestration split** (folded into `native.ex`).

**Net:** the native path carries ~4 retained geometry families + its own
request/identity/delivery families; it sheds ~4 dispatch/orchestration families.
The concept-count reduction is real but **modest** — and it is concentrated
entirely in the dispatch/orchestration column, not the geometry column, which is
exactly what Task 14's transitional scope predicted.

---

## 2. Change-locality benchmark (desk exercise)

For three representative changes, the concrete files each stack touches. This is
a **desk exercise** (enumeration, no implementation), derived from the module map
of each stack.

### 2a. Add a transform option — `sharpen`

**Framework** (product-neutral, shared by all dialects):
- `lib/image_pipe/plan/operation/sharpen.ex` (new declarative op) *or* extend an
  existing effect op struct
- `lib/image_pipe/transform/operation/sharpen.ex` (new executable op +
  `transform/2`, `requires_materialization?/1`)
- `lib/image_pipe/transform/neutral_resolver.ex` (lower the plan op → executable
  op; add a `continue` clause only if it needs a measure)
- **Each dialect parser that exposes it**: `parser/imgproxy/*` (option table +
  PlanBuilder), and any of `parser/iiif/*`, `parser/twicpics/*` that adopt it
- `test/.../transform/sequential_access_test.exs` (per-op sequential-safety gate)
- `fiddle/assets/` (demo controls + URL state) per Transform guidelines
- imgproxy conformance doc + wire tests if it maps to an imgproxy option

*Layers crossed:* Plan → Transform → Resolver → per-dialect Parser → demo.
*Per-dialect duplication:* one parser-table edit **per dialect** that exposes it.

**Native:**
- `lib/image_pipe/dialect/native/option_spec.ex` (option-table row + value
  coercion, à la `blur`)
- `lib/image_pipe/dialect/native/request.ex` (field on the request/operation set)
- `lib/image_pipe/dialect/native/pipeline.ex` (`group_operations` emits the
  `Plan.Operation`)
- **reuses** the same core `Plan.Operation.Sharpen` / `Transform.Operation` /
  `NeutralResolver` lowering added on the framework side — **no second geometry
  implementation**
- native wire test + option coverage

*Layers crossed:* Native option-table → Native request → Native pipeline (all
one boundary) + the shared core op.
*Per-dialect duplication:* none within native; the geometry op is shared core.

**Verdict:** a genuinely cross-cutting op (new pixel operation) still lands in
**shared core** for both stacks. The native surface adds one self-contained
option-table edit; the framework adds one parser-table edit *per participating
dialect*. Native wins locality only for the *surface* wiring, not the geometry —
matching the spec's prediction that the explicit flow "may lose cross-cutting
changes."

### 2b. Add a pixel-tapping terminal — `lqip` (LQIP-CSS)

The probe already shipped BlurHash (Task 17) as the worked precedent; `lqip`
would follow the same seams.

**Framework:** the framework has **no** complete-body terminal path today; adding
one would require new work in `Request.Runner`/`Processor` delivery, a terminal
identity, negotiation bypass, and the complete-body cache widening — a
cross-cutting change touching the frozen orchestration core.

**Native** (mirrors BlurHash, Task 17):
- `lib/image_pipe/output/terminal/lqip.ex` (new core terminal: `compute/1` +
  `identity/0`) — analogous to `Output.Terminal.Blurhash`
- `lib/image_pipe/dialect/native/option_spec.ex` (accept `output=lqip`)
- `lib/image_pipe/dialect/native/negotiation.ex` (`{:terminal, :lqip}` clause,
  `vary?: false`)
- `lib/image_pipe/dialect/native/identity.ex` (terminal identity material)
- `lib/image_pipe/dialect/native/pipeline.ex` (`terminal_reduction/1` +
  `reduce_terminal/3` clause)
- `lib/image_pipe/dialect/native.ex` (a `generate/6` `{:terminal, :lqip}` clause
  + fixed content type + complete-body cache write) — the branch already exists
  for blurhash; a second terminal is an additive clause
- native wire test

*Layers crossed:* Native (option→negotiation→identity→pipeline→delivery, one
boundary) + one new core terminal + the already-widened complete-body cache.
*Per-dialect duplication:* none.

**Verdict:** **native wins decisively.** The inverted stack already grew the
complete-body seam (Task 17); a new terminal is a handful of additive clauses in
one boundary + one small core terminal module. The framework would need to grow
a complete-body delivery path it doesn't have.

### 2c. Change cache-key material

**Framework:** `lib/image_pipe/cache/key.ex` (+ its tests) owns which fields
compose the key; the ETag/identity inputs live in `Representation` /
`Representation.IdentityMaterial`. A material change touches
`cache/key.ex`, the identity material assembly, and the cache-key tests — shared
by **all** dialects at once (one edit, global effect).

**Native:** `lib/image_pipe/dialect/native/identity.ex` (`material/4` — what the
dialect feeds into `Representation.build`) + `Representation` core if the *shape*
of the material changes. The `ContractKit.CacheKey` kit (Task 18) pins the
invariants for the native dialect and would be updated once.

*Per-dialect duplication:* here the **framework wins** — a cache-key change is
inherently cross-cutting, and the framework's single `Cache.Key` +
`Representation` composition applies it to every dialect in one place. Under the
inverted model each dialect owns its `Identity.material/4`, so a key-material
change that must reach *N* dialects is *N* edits. At the probe's N (native only)
this is one edit; the tax scales with dialect count.

**Verdict:** cache-key material is the case the spec flagged where the explicit
flow **loses** — cross-cutting identity changes fan out per dialect. `Cache.Key`
itself stays shared (both stacks call it); only the *material assembly* is
per-dialect under inversion.

### Summary

| Change | Native locality | Framework locality | Winner |
|---|---|---|---|
| add transform option (`sharpen`) | 1 boundary + shared core op | shared core op + parser edit per dialect | native (surface only) |
| add pixel-tapping terminal (`lqip`) | additive clauses, 1 boundary + 1 core terminal | needs a new complete-body delivery path | **native** |
| change cache-key material | per-dialect `Identity.material` (N edits) | one `Cache.Key`/`Representation` edit, global | **framework** |

This confirms the spec's hypothesis both directions: the explicit flow wins
localized/terminal changes and **loses** genuinely cross-cutting identity
changes. Both were measured, not assumed.

---

## 3. Error-path / ownership matrix

Every row is **read from Task 20b's green tests**
(`test/image_pipe/dialect/native_error_paths_test.exs`, 9 tests, one per row;
report `.superpowers/sdd/task-20b-report.md`). No test or implementation was
added in this task. Rows 6 and 9 have "nothing to clean up" ownership by nature.

| # | Row | Observed status / behavior | Cleanup owner | Error-translation owner |
|---|---|---|---|---|
| 1 | fetch failure (origin 5xx) | 502, body `"upstream responded 503"`, no partial 200, **cache sink never opened** | fetch bracket inside frozen core (`Source.with_fetched`/`Decode.with_image`); error surfaces before the dialect's own bracket runs | `Response.ErrorStatus.classify({:source,{:bad_status,503}})` → `:bad_gateway` → 502, via `Native.Errors.send/3` |
| 2 | client disconnect during fetch (pre-`pump`) | `Coordinator.prepare/1` caller unblocked with `{:error,{:session,{:owner_down,:killed}}}`; producer processes queued graceful-halt at next receive and runs its `try/after` **once** | Coordinator's owner-monitor requests graceful halt; the **producer's own `try/after`** runs cleanup | N/A (Coordinator lifecycle proof, no HTTP status) |
| 3 | decode rejection (415) | 415, no partial 200, **cache sink never opened** | `Decode.with_image`'s internal fetch+decode `try` (frozen core) | `ErrorStatus.classify({:decode,_})` → `:unsupported_media` → 415 |
| 4 | transform failure after partial work | 422; group 1 (resize) proven run via real `Chain.execute` before group 2 (blur) forced to fail; cleanup runs **exactly once** | `native.ex` `build_fun`'s own `try/after` (`on_bracket_exit` fires once) — decode already succeeded, so this is the **dialect-owned** bracket | `ErrorStatus.classify({:transform_error,inner})` → `:unprocessable` → 422 |
| 5 | encoder failure after first streamed chunk | 200 already committed (`conn.state == :chunked`), body is exactly the delivered prefix (`"first chunk"`); failure past that never reaches the wire | `native.ex` `build_fun` `try/after` fires once (`Producer.pump_loop` error branch returns `:done`, not a raise); `Coordinator.handle_producer_result({:error,_})` **aborts the cache sink** | `Response.Sender.continue_prepared_stream/2` gets `{:error,_}`, calls `prepared_stream.cancel.()` (no-op vs stopped coordinator), marks the conn processing-error flag; no status change possible post-chunk |
| 6 | cache-lookup failure (adapter `get/2` raises) | 200, correct decoded width; log `"cache read error: …"` — **fail-open** | none — nothing to clean up (this is the already-correct contract) | N/A — `Cache.fetch_entry/3`'s own `rescue` → `{:miss, …}` → `generate/6` treats as plain miss |
| 7 | cache-write failure (adapter `write_chunk/3` errors) | 200, correct decoded width; `open_sink` → one failing `write_chunk` → `abort_sink`, `commit_sink` **never** called — fail-open | `Cache.Sink.do_write_chunk/3`'s own `emit_abort_cleanup` (production code) aborts the adapter sink synchronously; subsequent writes/commit no-op | N/A — fail-open, no error status |
| 8 | producer cancellation (`cancel/0` after first chunk) | `Coordinator.cancel/1` returns `:ok`; sink `abort_sink`, never `commit_sink`; cleanup **once**; both children terminate | `Coordinator.handle_producer_result(:ok, %{pending:{:cancel,_}})` → `abort_cache_sink`; producer `try/after` runs cleanup once | N/A — explicit cancellation, not an error |
| 9 | response-already-sent | after normal `:done`/stop, a further `Coordinator.next/1`/`cancel/1` returns `{:error,{:session,:noproc}}` — never crashes the caller | none — session already fully torn down | `Coordinator.call_session/3`'s `catch :exit, {:noproc,_} → {:error,{:session,:noproc}}` (production code) |

### Ownership answers (spec §Error-path completeness)

- **Who owns the source session after encode preparation?** The
  `Native.Delivery.Coordinator`, monitoring the conn owner via
  `Process.monitor(owner)` (the `Request.SourceSession` precedent). The fetch +
  decode brackets live *inside* the producer, inside `Decode.with_image`; lazy
  resources never escape the bracket.
- **Who closes it on normal completion?** The producer's own `try/after` fires
  on EOF; `Coordinator.handle_producer_result({:ok,:done},…)` commits the sink
  and stops `:normal`.
- **Who aborts on client disconnect?** The Coordinator's owner-monitor
  `handle_info` requests a graceful producer halt; the producer's `try/after`
  runs cleanup (row 2).
- **Who finalizes/aborts the cache sink?** `Coordinator` — commit on `:done`,
  `abort_cache_sink` on `{:error,_}`/cancel/owner-down. Write-time adapter errors
  are aborted synchronously inside `Cache.Sink` itself (row 7).
- **Encoder-fails-after-first-chunk:** the 200 is already committed and chunked;
  the stream halts at the delivered prefix, the sink aborts, cleanup runs once,
  no status/body change is possible (row 5).

**Ownership count:** cleanup is owned in **two** clearly-delineated places —
frozen core brackets (`Source.with_fetched`/`Decode.with_image`) before decode
completes (rows 1–3), and the dialect-owned `build_fun` `try/after` +
`Coordinator` after decode completes (rows 4–5, 7–8). Error *translation* is
owned in **one** place: `Response.ErrorStatus` + `Native.Errors.send/3`. The
error paths stayed readable — the spec's success condition ("if the dialect chain
stays readable under these, the design has actually succeeded").

### Found bug (recorded, NOT fixed here — separate session)

`ImagePipe.Cache.Sink.open_adapter_sink/4` has **no `rescue`** around
`adapter.open_sink(key, metadata, cache_opts)`, unlike its two siblings
(`do_write_chunk/3` and `emit_commit_result/2`, which both rescue). A cache
adapter that **raises inside `open_sink/3`** therefore crashes the `Coordinator`
mid-`handle_info` and surfaces to the client as a bare **500**, violating the
"cache errors fail open" contract (Cache guidelines). This is shared core code
(also on the framework's `Runner`/`Plug` path), not native-specific. Discovered
while designing row 7; deliberately not turned into a red test (gate discipline).
Fix shape is narrow (add the missing `rescue`, mirroring the two siblings). **It
is being fixed in a separate user session (chip `task_1a2491bf`) — out of probe
scope; recorded here only.**

### Dialyzer finding surfaced by the final gate (fixed here)

The final `mise run precommit` gate (which runs `mix dialyzer` between credo and
test — a step the per-task gates skipped, so it was latent since Task 15) flagged
a provably-dead defensive clause in
`ImagePipe.Dialect.Native.Delivery.Coordinator.with_owner_check/2`
(`coordinator.ex:338`): a `nil ->` branch on `state.pending` that Dialyzer's
success typing proves unreachable, because all three call sites
(`handle_producer_result/2`) invoke it only with `state.pending` set to
`{:prepare, from}` or `{:next, from}`. Per the project guideline "delete behavior
for impossible internal misuse instead of adding guards," the dead inline branch
was removed by delegating to the existing `reply_pending/2` helper (whose own
`nil` clause stays legitimately reachable from the producer-down `handle_info`
path). Behavior-preserving; covered by Task 20b row 2 (owner-down). Non-frozen
dialect code.

### Known limitation (recorded, from Task 15 Opus review)

The graceful-halt "cleanup exactly once" guarantee holds for the streamed /
fast-chunk case (rows 4/5/8). It does **not** hold unconditionally: a **slow
single synchronous encode** whose first chunk carries a whole >1s AVIF/WebP
encode can sit past the `Coordinator`'s `producer_halt_timeout` (1000ms)
force-kill backstop, which `Process.exit/2`s a wedged non-trapping producer and
**skips its `try/after`**. This is an accepted, documented tradeoff in
`Delivery`'s moduledoc (libvips handle is NIF-GC'd, no worse than the framework's
`SourceSession`), not a new discovery. The report states it honestly: cleanup
is exactly-once for the streamed case, best-effort with a force-kill backstop for
a slow single encode — not unconditional.

---

## 4. Orientation-invariance matrix

Summary of Task 19 (`.superpowers/sdd/task-19-report.md`;
`test/image_pipe/dialect/native/orientation_matrix_test.exs`, 27 tests). **All
cells pass. No #146 leak was found in Tasks 11/12/14.**

| EXIF orientation | `region=10,20,100,200` | `crop=100,80/anchor=top-left` | `fit=cover/w=150/h=100/focus=0.75,0.25` | plain `w=160` |
|---|---|---|---|---|
| 1 (identity) | PASS | PASS | PASS | PASS |
| 6 (90° quarter turn) | PASS | PASS | PASS | PASS |
| 8 (270° quarter turn) | PASS | PASS | PASS | PASS |

Each cell asserts three invariants:

1. **Semantic-intent invariance** — the dialect's op-*kind* sequence
   (`{module, crop_from_kind, gravity_kind}`, `Flush` stripped) is identical
   across storage orientations. `group_operations/2` reads only `display_dims` +
   group config (both storage-orientation-invariant), so it never branches on
   storage orientation; only core's downstream numeric resolution and the
   orientation-driven `Flush` legitimately differ.
2. **Pixel invariance** (wire-level twin oracle) — full-frame `PixelCompare`,
   exact `same_dims?` then `fraction_over(…,40) < 0.05`. A real storage/display
   frame mixup shifts the whole content window and blows past the 5% bound; the
   bound stays tight to remain a real discriminator, generous per-sample only to
   absorb the oriented leg's JPEG re-encode ringing.
3. **Shrink correctness** — decode shrink uses **storage** dims while semantic
   planning uses the **display** (planning) frame. Measured: EXIF-6
   1600×1200-storage source, `w=300` → `decode_request.resize_target == {300,
   400}` (resolved against display 1200×1600), real loaded pre-flush dims exactly
   `{400,300}` (shrink 4). The discriminating counter-case (shrink computed
   against unswapped storage dims → shrink 2 → `{800,600}`) is documented in the
   test, giving it teeth.

The assertion is exactly the exit criterion's: **dialect code produces the same
semantic crop/resize intent regardless of storage orientation; only core
performs storage-frame compensation.** The inversion did **not** leak #146's
complexity back into the dialect.

### Documented subset limitation (auto-rotate-OFF arm)

The native URL grammar has **no `orient=` option** — EXIF auto-rotate is a fixed
policy (`@auto_rotate? true`). The exit criterion's "auto-rotate OFF" arm is
therefore **not exercisable end-to-end** through this dialect. It is validated
only at the **core** level by `Transform.SourceGeometry.planning_frame(geometry,
false)` unit tests (Task 12). The matrix test pins the absence of the escape
hatch directly (`Parser.parse` of `orient=none` → `{:error, {:invalid_request,
_}}`). This is a documented subset limitation, not a silent reduction.

### Logged strengthening item (post-probe)

Assertion 1 tests op-**kind** equality, not exact pre-resolve struct equality,
because there is no test-only seam to intercept the dialect's *pre-resolve*
`Plan.Operation` batch (only the post-`NeutralResolver` executable ops are
capturable via the `:chain` seam, and those legitimately differ under storage
compensation). Pre-resolve `Plan.Operation` twins **would** be exactly equal — a
stronger invariant, blocked only by the lack of a test seam. A minimal test-only
hook after `Pipeline.group_operations` (analogous to `run/4`'s
`:chain`/`:measure_dims`/`:continue` overrides) would let a future test assert
exact pre-resolve semantic-op equality. Production-code change, out of scope for
the test-only Task 19; logged here for post-probe.

---

## 5. Ordered-planning spike

Summary of Task 20 (`.superpowers/sdd/task-20-report.md`;
`test/support/image_pipe/ordered_spike/pipeline.ex`,
`test/image_pipe/ordered_spike_test.exs`). A synthetic TwicPics-like ordered
interpreter over `[{:resize_w,500},{:crop_rel,0.5,0.5},{:resize_w,200}]`-shaped
command lists, evaluated left-to-right with carried `%{dims:{w,h}}` state.

### (a) No callback seam needed

`run/3` is a single `Enum.reduce_while` over the command list. Each command
computes its executable `Transform.Operation.*` struct directly from a live
`{Image.width, Image.height}` read, calls `Chain.execute/3`, re-measures,
continues. **No** `Plan.Operation` semantic struct, **no** `NeutralResolver`,
**no** `{ops, continuation}` vocabulary, **no** `Resolver` strategy dispatch —
ordinary Elixir control flow is the entire "framework." This validates the
inversion for the *harder* ordered case: even a grammar whose evaluation order
matters and whose geometry is unknown until a prior command runs needs no new
generic strategy/callback abstraction — only the existing primitives
(`Chain.execute/3`, `Transform.Operation.*`, a live dims read).

Two honest wrinkles: (i) `run/3` must clear
`state.source_dimensions`/`decode_shrink` before running commands, or core's
"residual resize sizes against the exact original extent" contract
(`State.effective_source_dims/1`) would silently ignore an earlier `:crop_rel`;
(ii) the spike flushes deferred orientation **eagerly** (before the first
command), costing the streaming fast path for a materializing quarter-turn
source — a deliberate simplification, not a fundamental blocker.

### (b) The decode-bound answer

`preflight/2` walks the command list **backward**, carrying a per-axis
requirement (`:unbounded` initially), with three rules:

1. **Absolute op reset** (`:resize_w`/`:resize_h`): the op's own axis becomes a
   concrete pixel floor; the other axis becomes `:derived` (decoupled from
   anything further downstream). Sound because shrink-on-load applies one uniform
   scalar and header aspect ratio is shrink-invariant. Hand-verified:
   `[resize_w(500),crop_rel(0.5,0.5),resize_w(200)]` → floor **500**, not the
   naive 400.
2. **Relative op propagation** (`:crop_rel`): each axis scales up by the
   reciprocal of its fraction (`req/fx`). `:unbounded`/`:derived` pass through.
3. **Unknown-until-measured collapse** (`:trim`): the whole requirement collapses
   to `:no_shrink`, short-circuited up front — `:trim`'s output extent is
   *content-dependent* (a shrunk decode can resample different pixel values), so
   only a full-resolution decode is safe, and a single decode serves the whole
   list, so `:trim` anywhere taints everything.

Failure cases: **#1 no anchor, no bound** — a purely relative list stays
`:unbounded` → `:no_shrink` (final dims are directly proportional to header
size). **#2 `:trim` anywhere** → `:no_shrink`. **#3 rounding compounds** (see
below).

### (c) THE KEY DISCOVERY — `required_extent` is mechanically inert

The brief anticipated the "own field" evidence would be *semantic* (misusing
`resize_target`'s output-box meaning for a floor is a category error). The spike
found something **stronger and mechanical**, confirmed directly against
`DecodePlanner.open_options_for/5`:

```
only required_extent:      [access: :sequential, fail_on: :error]
resize_target as {200, 1}: [access: :sequential, fail_on: :error, shrink: 8]
```

`required_extent` is **not merely semantically mismatched — it is mechanically
inert alone.** `compute_load_shrink_for_request/3` (which produces the shrink
ratio) never reads `required_extent`; only `cap_to_required_extent/4` does, and
only *after* a ratio has already been computed from `trim?`/`resize_target`/
`terminal_reduction`. With none of those set — exactly `Pipeline.decode_request/2`'s
shape — the pre-cap shrink is always `1.0`, and capping `1.0` to any floor
`≥ 1.0` leaves it at `1.0`. **So an ordered dialect carrying only a preflight
floor via `required_extent` gets ZERO decode-on-load savings.**

Proven two ways: a `DecodePlanner`-unit test (floor alone → no load options; same
floor paired with `resize_target` → real `shrink: n`) and end-to-end
(`Pipeline.decode_request/2` with `required_extent` only → `state.decode_shrink
== nil` even for a tight, correct 200px floor).

**This is the concrete "ordered spike needs its own field" evidence:**
`DecodePlanner.Request` is **Native/declarative-shaped** — `required_extent` was
built as a *cap paired with a driver* (Native's shape:
`resize_target`/`crop_extent`/`trim?`/`terminal_reduction` drive,
`required_extent: nil`), not as a standalone shrink-driver. An ordered dialect
needs a shrink-**driving** preflight field (a floor that *is* the desired
target), which the typed request does not currently expose. Closing this is a
small, mechanical `DecodePlanner` change (let `required_extent` alone drive
`load_shrink` when no other field is set), out of the spike's frozen-file scope.

### Measured cost where no bound exists (rounding, finding #3)

The soundness of rules 1/2 is exact in real arithmetic but every stage rounds to
integer pixels, and this interpreter measures the already-decode-rounded live
image at every step, so rounding **compounds** (strictly worse than core's
single-resolve ±1px). Calibrated empirically (offline 3000-sample sweep over the
property generator shape): **max drift 2px (~1 in 1500 cases); 1px ~1 in 16;
exact otherwise.** The shipped property test asserts ±2px, documented as
empirical (not a proven constant — a deeper ordered pipeline could compound
further). This is a genuine new finding beyond the existing single-resize ±1px
result, and a real (if minor) semantic cost of the "measure the live image at
every step" design. **The property pins geometry soundness only — not pixel
content**, and (like Native) applies **no color management** (sRGB-correct,
diverges for ICC/wide-gamut).

---

## 6. Core-exports list (the draft toolkit surface)

Grep of `lib/image_pipe/dialect/**` + `test/support/image_pipe/contract_kit/**`
for `ImagePipe.` references, grouped.

### 6a. Pre-existing exports consumed unchanged

`ImagePipe.Source.resolve`, `Source.Resolved`; `ImagePipe.Cache` (`open_sink`,
`write_chunk`, `commit_sink`, `Entry`); `ImagePipe.Output` (`Policy`, `Clamp`,
`Encoder.stream_output`, `Format`); `ImagePipe.Transform` (`Chain.execute`,
`NeutralResolver.resolve`/`continue`, `State`, `SourceShape`,
`PendingOrientation`, `Operation.Flush`,
`DecodePlanner`); `ImagePipe.Response` (`Sender`, `PreparedStream`);
`ImagePipe.Plan` (`Output`, `Response`, `Source`, `Operation`, `Measure`,
`Color`); `ImagePipe.Telemetry`; `ImagePipe.Error`.

### 6b. Exports WIDENED for the probe (new fn / new arity on an existing boundary)

- `Transform.SourceGeometry` (+ `planning_frame/2`, `display_dims`) — Task 12
- `DecodePlanner.Request` (typed request struct) + `DecodePlanner.open_options_for/5`
  — Task 11
- `Response.Conditional` (`not_modified?/2`, `if_none_match_wildcard?/1`) — Task 16
- `Response.ErrorStatus.classify/1` — Task 15
- `Cache.lookup_entry/2` — Task 9
- `Output.Policy.identity_selection/1` + `Output.Policy.identity_material/1` —
  Task 9/10
- The **complete-body** `Cache.open_sink/3` `{:complete_body, content_type}`
  variant + tagged `Entry` `representation: {:image,_} | {:complete_body,_}`
  metadata + matching `Entry` validation branch — Task 17
- `Source.with_fetched` (fetch bracket) — Task 12
- `Output.Terminal.Blurhash` (`compute/1`, `identity/0`) — Task 17
- `Plan.Color.rgb_name/1` (external `color` dep behind the core boundary) —
  user-directed color expansion (commit 545ea60d)
- `Representation` (`build/2`, `storage_inputs/2`) + `Representation.IdentityMaterial`

### 6c. NEW core boundaries introduced by the probe

- `ImagePipe.Representation` (+ `Representation.IdentityMaterial`) — the
  pre-fetch identity surface (key/ETag/Vary material), consumed but not owned by
  the dialect.
- `ImagePipe.Decode` (+ `Decode.SourceFormat`) — the fetch+decode bracket
  (`with_image/4`) as a reusable core primitive.

### 6d. DUPLICATED-not-extracted (the real toolkit-surface gaps)

| Duplicate | Origin | Framework equivalent | Recommendation |
|---|---|---|---|
| **delivery session / producer / coordinator** (`native/delivery.ex`, `delivery/coordinator.ex`, `delivery/producer.ex`) | Task 15 | `Request.SourceSession` + `Request.SourceSession.Producer` | **EXTRACT (top candidate).** See below. |
| Processor decode internals + `Decode.SourceFormat` | Task 12 | `Request.Processor` two-open flow + `Request.SourceFormat` (in the forbidden `Request` boundary) | **Keep duplicated for now** — the `Decode` boundary already generalized the *bracket*; `SourceFormat` is a tiny classification table deliberately re-homed out of the forbidden `Request` boundary. Extract into a shared `Format`-adjacent home if a second consumer appears. |
| conditional-match logic | Task 16 | `Request.Runner`'s post-cache conditional evaluation | **Keep duplicated** — `Response.Conditional` is already the shared home; the native path deliberately runs it *earlier* (pre-fetch) than `Runner` does. Behavior differs by design (stricter), so this is not a true duplicate. |
| `open_options_for/5` alongside `open_options` | Task 11 | `DecodePlanner.open_options` (chain path) | **Keep duplicated (transitional)** — see §7; the `Request`-shaped field set is the transitional dependency, and the `required_extent`-inertness finding (§5c) means the *toolkit-shaped* variant is still owed. |
| complete-body cache widening | Task 17 | framework produces only `{:image,_}` entries | **Keep as-is (additive)** — the `{:complete_body,_}` variant is purely additive and leaves the framework's `{:image,_}` path byte-identical. N/A to extract. |

**Top extraction candidate — the delivery session/producer (foregrounded).** A
user explicitly asked whether this neutral streaming lifecycle belongs in core.
It does: the framework already has `Request.SourceSession` /
`Request.SourceSession.Producer` doing the identical job (monitored producer
pumping chunks inside the fetch/decode brackets, cancellable on owner
disconnect, incremental cache write). Decision 5 **deliberately deferred**
generalizing the framework's `Producer` to post-probe ("the dialect gets its own
simplified session/producer… generalizing the framework's Producer is
post-probe, recorded in the core-exports report"). This is the probe's clearest
"generalize into core" finding and is in direct tension with **Design Principle 1**
(core owns lifecycle-mechanic primitives; the dialect composes them — Task 12 did
extract `Source.with_fetched`/`Decode.with_image`, but the delivery producer was
**not** extracted). **Recommendation: extract a neutral streaming-delivery
lifecycle primitive into core** (`ImagePipe.Response.*` or a new `Delivery`
boundary) that both `Request.SourceSession` and a future migrated dialect
consume, as the first post-probe toolkit-hardening step. It is a deliberate
deferral, not an accidental misplacement.

### 6e. Telemetry surface

Task 15 added `:sig_key_index` to the native `[:parse]` stop metadata and to
`Telemetry.Trace.Capture`'s `@safe_keys`. **Verified already documented** in
`docs/telemetry.md` (line 537) and present in `capture.ex` (`@safe_keys`, line
81) — no telemetry doc change was needed in this task.

---

## 7. Direct-lowering feasibility

**Question (Task 14's required assessment):** what would a dialect-callable core
"geometry compiler" API need to expose for the `Plan.Operation` /
`Transform.Operation` mirror **and** the `{ops, continuation}` vocabulary to
actually die?

**The blocker is the deferred-orientation flush/compensation policy.** The reason
Task 14 retained the mirror + continuation vocabulary (rather than assembling
executable `Transform.Operation.*` directly) is that direct assembly would force
the dialect to own the deferred-orientation flush and the storage-frame
compensation of crop gravity + resize dimensions — exactly the #146 leak the
orientation exit criterion (Task 19) forbids. `NeutralResolver` +
`SourceShape` + the `follow/5` measure loop are precisely the machinery that
keeps that policy in **core**. For the mirror to die, a core geometry-compiler
API must expose that policy as a **dialect-callable primitive**: something like
"given display-frame semantic intent + a `SourceGeometry` (storage dims + pending
orientation), return the storage-frame executable ops **plus** the flush,
already compensated" — so a dialect can lower directly without re-deriving the
compensation. Until that exists, direct lowering re-leaks #146.

### Transitional dependencies (explicit)

The probe's native path depends on these core shapes *as they are today*; each is
a thing the post-probe toolkit must generalize before the mirror can collapse:

1. **Direct `%Plan.Output{}` construction** — `Native.Identity.plan_output/1`
   builds a `%Plan.Output{mode:…, quality:…}` by hand (identity.ex:80–84) to feed
   `Policy.from_output_plan`. The dialect reaches into the framework's plan output
   struct rather than a neutral output-intent value.
2. **`Policy.identity_material/1`'s coupling to the `%Policy{}` struct shape** —
   identity derivation reads fields off the core `%Output.Policy{}` struct. The
   one-`%Policy{}` continuity invariant (the same policy value in
   `negotiation.policy_material` and in the `%Output.Resolved{}` that reaches the
   encoder) is structural, pinned by a continuity test, but it means the dialect's
   identity is coupled to the policy struct's internal shape.
3. **The `DecodePlanner.Request` field set is Native/declarative-shaped, not
   toolkit-shaped** — proven mechanically by §5c: `required_extent` is a cap
   paired with a driver, inert alone. An ordered/toolkit consumer needs a
   shrink-driving floor field the struct does not expose. The typed request is
   currently the *native dialect's* shape, borrowed by the ordered spike, not a
   neutral toolkit contract.
4. **The retained continuation vocabulary** — `{:advance, shape, state}` /
   `{:measure, tag, state}` + the named measure tags remain the interface between
   the dialect's `follow/5` driver and `NeutralResolver`. This is the mirror's
   spine; it lives or dies with the flush-policy question above.

### Recommendation for the post-probe decision

The mirror **can** die, but only after core exposes a display-frame→storage-frame
geometry-compiler API that owns the deferred-orientation flush/compensation. That
is a real, scoped piece of work (promote the `NeutralResolver` + `follow` +
`Flush` policy into a dialect-callable helper), and it is the prerequisite the
spec named. Until then, retaining the mirror is the correct, honest choice — it
keeps #146 in core where Task 19 proved it stays contained. Sequence the
post-probe work as: (1) extract the delivery lifecycle primitive (§6d, the
already-deferred Decision 5 item); (2) add the toolkit-shaped shrink-driving
preflight field to `DecodePlanner.Request` (§5c); (3) expose the geometry-compiler
flush/compensation API (this section) that finally lets the operation mirror and
continuation vocabulary collapse.

---

## Exit-criteria cross-check (spec §Exit criteria)

Every spec exit-criteria bullet, cross-checked against the probe's artifacts.

| # | Exit criterion | Status | Evidence |
|---|---|---|---|
| 1 | Native dialect serves real requests end-to-end (geometry+effects, negotiation+`Vary`, signing, `then` groups, ETag/304 before fetch, cache hit/miss with incremental sink, streamed delivery w/ cancellation) | **Satisfied** | Tasks 15 (image terminal, streaming, cache write, wire tests), 16 (conditional GET + hit + 304-before-fetch), 17 (blurhash complete body); wire tests green |
| 2 | `ContractKit.CacheKey` + `ContractKit.RequestSafety` exist and pass against native | **Satisfied** | Task 18 (`test/support/image_pipe/contract_kit/{cache_key,request_safety}.ex`) |
| 3 | Hop-count/concept-count comparison | **Satisfied** | §1 (honest: raw hops ~16 vs ~14 baseline; win is dispatch seams 5→~1) |
| 4 | Change-locality benchmark (3 changes, per-stack modules/layers/tests/duplication) | **Satisfied** | §2 (native wins terminal/localized, framework wins cache-key material) |
| 5 | Error-path completeness (9 rows) + ownership | **Satisfied** | §3, Task 20b (9 green rows); found `open_sink` bug recorded, separate session |
| 6 | Orientation-invariance matrix (auto-rotate on/off × identity/90°/270° × crop/resize) | **Satisfied with documented subset limitation** | §4, Task 19 (all cells pass; auto-rotate-OFF arm validated at core `planning_frame(_,false)` only — no `orient=` in the subset) |
| 7 | Written list of core exports the probe needed | **Satisfied** | §6 |
| — | Ordered spike + decode-bound answer (spec §The probe) | **Satisfied, with recorded cost** | §5, Task 20 (`required_extent` inert → zero ordered decode savings without a new field; ±2px compounding) |

### Explicit gaps and open items

- **G1 — Auto-rotate-OFF not exercised end-to-end** (criterion 6). No `orient=`
  in the native subset; validated only at core unit level (`planning_frame(_,
  false)`, Task 12). Documented subset limitation, §4.
- **G2 — Ordered decode-on-load win is currently unrealizable** (§5c).
  `required_extent` is mechanically inert alone; the ordered dialect earns zero
  decode-time benefit until `DecodePlanner.Request` grows a shrink-driving floor
  field. Measured, not hypothetical.
- **G3 — `Cache.Sink.open_adapter_sink/4` fail-open bug** (§3). A raising
  adapter `open_sink/3` → 500 instead of fail-open. Being fixed in a separate
  session; recorded, not fixed here.
- **G4 — Input color management not applied** by the native image terminal
  (Task 14 known limitation). `Decode.with_image` does not seed working-space
  import; the native pipeline does not add a preamble mirroring
  `Executor.seed_color_management`. Correct for sRGB, diverges for
  ICC/wide-gamut. The blurhash terminal handles color internally. Would need
  exporting `InputColorManagement` as a dialect-callable preamble.
- **G5 — Complete-body cache not persisted by `Cache.FileSystem`** (Task 17
  Minor). `Cache.FileSystem` does not persist the `{:complete_body,_}`
  representation tag → a FileSystem-cached blurhash entry is lost across restart,
  **fail-open** (safe). Mechanical fix for whoever wires FileSystem as a prod
  blurhash cache.
- **G6 — Graceful-halt force-kill backstop** (§3). Cleanup is exactly-once for
  the streamed case, best-effort (1s force-kill, `try/after` skipped) for a slow
  single synchronous encode. Documented tradeoff, not unconditional.

### Open design-owner items (unpinned probe defaults — confirm/adjust post-probe)

- **`trim=color` default tolerance `0`** (Task 5) — no spec anchor; a reasonable,
  tested probe default.
- **`trim=auto` default threshold `10.0`** (Task 14) — no spec anchor; a
  reasonable, tested probe default.

### Post-probe strengthening / sync (logged, not blocking)

- Op-KIND vs exact pre-resolve `Plan.Operation` equality in the orientation
  matrix needs a test seam after `Pipeline.group_operations` (§4).
- Spec §Error-diagnostics worked example underlines the whole `bogus=10` (8
  carets) but the RULE says underline the key → parser correctly underlines the
  key only (`bogus`, 5). Fix the spec example's caret count post-probe.

---

## Final gates

Two environment/gate issues surfaced when running the full `mise run precommit`
(which runs, in order: `format --check-formatted`, `compile
--warnings-as-errors`, `credo --strict`, `dialyzer`, ExDNA duplication, `test` —
note it includes `dialyzer` and duplication, which the per-task gates did not):

1. **10 JXL test failures — environmental, provisioned.** The worktree's
   `vix` 0.39.0 was not built against a JXL-capable libvips (`jxlsave_buffer`
   undefined), while the platform Homebrew libvips 8.18.2 does ship
   `VipsForeignSaveJxl`. Per "fix env not skip tests," `vix` was rebuilt with
   `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS` against the platform libvips;
   `jxlsave_buffer` then works and the 10 failures clear. No source change; a
   build-artifact fix only.
2. **1 Dialyzer error — fixed** (see §3 "Dialyzer finding surfaced by the final
   gate"): the dead `nil ->` clause in `coordinator.ex:338`.
3. **ExDNA duplication gate — config mirrored.** The standalone `mix ex_dna`
   step reported all 22 of the probe's **deliberate, blessed** dialect↔framework
   duplications (§6d: `Decode`/`SourceFormat` vs `Request.Processor`/
   `SourceFormat`; `Native.Pipeline` vs `Transform.Executor` helpers;
   `Native.Delivery.{Coordinator,Producer}` vs `Request.SourceSession`/
   `Producer`; `Response.Conditional` vs `Request.HTTPCache`). The `ExDNA.Credo`
   plugin already `ignore:`s exactly these six files in `.credo.exs` (with full
   justifications) — which is why `mix credo` passed — but the standalone
   `mix ex_dna` line in `mise.toml` was missing the matching `--ignore` globs, so
   the two duplication gates had diverged. Because dialyzer/JXL halted every
   earlier full-precommit run before this step, the divergence was latent since
   ~Task 12. Fixed by mirroring the `.credo.exs` ignore list into the `mise.toml`
   `mix ex_dna` invocation — config only, no source change, and the ignored
   duplications are the ones §6d already recommends extract/keep decisions for.

After all three, `mise run precommit` is green. See the meta-report
(`.superpowers/sdd/task-21-report.md`) for the recorded result and commit.

# Execution flow

How a request actually moves through the code at runtime — the call spine, the
two operation vocabularies, the resolve loop, and the places where static
"go to definition" navigation stops working and what to do there. Read this
alongside the [custom parser guide](custom_parser_guide.md), which documents
the *contracts*; this page documents the *flow*.

## The call spine

```
ImagePipe.Plug.call
└─ parser.parse(conn, opts)              ①  → %ImagePipe.Plan{}
└─ Plan validation (prefetch-safe shape checks)
└─ ImagePipe.Source.resolve                 (source identity — no bytes yet)
└─ HTTP conditional check                   (ETag match → 304, before any fetch)
└─ ImagePipe.Request.Runner.run
   └─ cache lookup ── hit? → stream stored entry
   └─ miss: ImagePipe.Request.Processor
      ├─ fetch → format gate → decode (sequential, shrink-on-load) → safety limits
      └─ ImagePipe.Transform.execute_plan
         └─ ImagePipe.Transform.Executor.execute
            ├─ seed EXIF orientation (pending, deferred) + input color management
            └─ per pipeline: seed ImagePipe.Transform.SourceShape, fresh strategy state
               └─ Executor.run — the resolve loop               ← the heart
                  loop over PLAN operations:
                  ├─ overlay shape → State                       (the one sync site)
                  ├─ ImagePipe.Resolver.resolve    ②             → {executable_ops, continuation}
                  ├─ ImagePipe.Transform.Chain.execute  ③        (materialize-if-needed + op.execute)
                  └─ continuation                  ④
                       {:advance, shape, state}  → next plan op
                       {:measure, tag, state}    → measure dims → strategy continue(tag, …), maybe more stages
   └─ encode (lazy) → Producer/PreparedStream: chunked streaming,
      cancellable on disconnect, incremental cache write → Response.Sender
```

Everything above `Runner.run` is request plumbing; everything below
`execute_plan` is pixel geometry. The step most readers get lost in is the
resolve loop, so the rest of this page is mostly about that.

## The two operation vocabularies

There are two different kinds of "operation", and the resolver strategy is the
translator between them:

- **`ImagePipe.Plan.Operation.*`** — what parsers emit. Declarative, possibly
  deferred (`:auto` dims, `:deferred` guides, `{:effective, …}` scales). These
  structs **never execute**.
- **`ImagePipe.Transform.Operation.*`** — executable: fully parameterized,
  every dimension concrete, every gravity a real point. These are what
  `Chain` runs, and one plan op may lower into several of them (a cover =
  a resize *then* a result crop).

When you are reading a `%Plan.Operation.Resize{}` and wondering "where do the
pixels happen" — they don't, until a strategy lowers it inside
`Executor.run`'s loop.

## The resolve loop and continuations

For each pipeline, `Executor.execute` seeds a `SourceShape` — a pure geometry
value (dims, which frame they describe, pending orientation, decode shrink) —
and fresh strategy state from the strategy's `init/0`. `Executor.run`
then walks the plan operations:

1. **Overlay.** The resolver-advanced shape is written onto `State`
   (`pending_orientation`, `decode_shrink`, `source_dimensions`) — the single
   place shape and State sync.
2. **Resolve.** `Resolver.resolve(strategy, shape, plan_op)` returns the
   executable ops for this plan op plus a *continuation*.
3. **Execute.** The ops run through `Chain.execute` (which materializes to RAM
   first if an op requires random pixel access).
4. **Continue.** The continuation is plain data saying how to learn the
   post-op geometry:
   - `{:advance, new_shape, new_state}` — the strategy computed it purely;
     move to the next plan op.
   - `{:measure, tag, state}` — it can't be known without looking (after a
     trim; after a resize whose realized dims may round ±1). The driver
     measures the live image's dimensions and calls the strategy's
     `continue(tag, {w, h}, shape, state)` — `shape` being the pre-op shape
     the strategy resolved against — which returns either the final
     `{shape, state}` or **another** `{ops, continuation}` stage to execute —
     that is how a cover emits its result crop parameterized against the
     *measured* post-resize dims. Recursion depth equals the emission's stage
     count (2 for a cover), never unbounded. Every tag is a named clause in
     the strategy — grep `NeutralResolver.continue` for the full vocabulary
     (`:rotate`, `:trim`, `:resize`, `{:resize_tail, …}`,
     `{:resize_flush_tail, …}`).

Two rules make the state story followable:

- **The continuation is the only strategy-state channel.** The driver never
  inspects strategy state; it threads whatever the strategy returned into the
  next `resolve/3` call. State is per-pipeline and dies with it.
- **Delegation re-wraps.** Custom strategies delegate shared geometry to
  `ImagePipe.Transform.NeutralResolver` (a stateless strategy) and must
  substitute their carry into its stateless continuations via
  `ImagePipe.Resolver.rewrap/2` (plain data threading); at a measure seam,
  their `continue/4` delegates the tag to `NeutralResolver.continue/4` and
  re-attaches the carry — see the
  [custom parser guide](custom_parser_guide.md#geometry-resolution-custom-resolver-strategies).

At the pipeline boundary the driver flushes any surviving non-identity pending
orientation through an explicit `%Flush{}` (an identity pending is cleared
without materializing — the streaming fast path).

## Where "go to definition" stops working

The flow crosses a handful of dynamic-dispatch and injection points. Each is
deliberate (pluggability or test seams), and each has a short list of real
targets:

| # | Call site | What it dispatches to | How to navigate |
|---|---|---|---|
| ① | `parser.parse(conn, opts)` in `ImagePipe.Plug` | The mount's `:parser` module | Three in-tree parsers: `ImagePipe.Parser.Imgproxy`, `.IIIF`, `.TwicPics` — each ends in a `PlanBuilder` that constructs the `%Plan{}` |
| ② | `Resolver.resolve(strategy, …)` facade | `plan.resolver`, defaulting to `NeutralResolver` in `Executor` | Three implementations: `ImagePipe.Transform.NeutralResolver` (all shared geometry — when in doubt, the answer is here), `ImagePipe.Parser.Imgproxy.Resolver` and `ImagePipe.Parser.TwicPics.Resolver` (thin dialect wrappers that delegate to Neutral) |
| ③ | `chain.(state, ops, opts)` in `Executor` | Injected function; always `Chain.execute/3` in production | Test seam only. Inside `Chain`, `Transform.execute(op, state)` dispatches to the op struct's own module — struct name = module name (`%Operation.Crop{}` → `transform/operation/crop.ex`) |
| ④ | `Resolver.continue(strategy, tag, …)` in `Executor` | The strategy's `continue/4` — one named clause per tag | Tags are data: grep the tag atom (e.g. `:resize_flush_tail`) to land on both the emitting resolve row and the continue clause. Neutral tags live in `NeutralResolver.continue/4`; dialect strategies delegate the tag and re-attach their carry |
| — | `render: {:custom, module, params}` | The plan's renderer module via `ImagePipe.Renderer` | Two in-tree renderers: the imgproxy and IIIF info renderers |
| — | `Telemetry.span(…, fn -> … end)` wrappers | n/a | Nearly every layer wraps its real call in a span closure; when lost, skip to the closure body |

Also note `render: :image` vs custom renders fork early: a custom render
(info.json) runs no transform stage at all — `Runner` short-circuits to the
renderer with header facts only.

## Suggested reading order

1. `ImagePipe.Plug.do_call_with_plan/4` — the request skeleton and error fan-out.
2. `ImagePipe.Request.Processor.process_decoded_source/4` — decode → transform → encode hand-offs.
3. `ImagePipe.Transform.Executor.execute_pipeline/4` — shape seeding, strategy selection.
4. `ImagePipe.Transform.Executor.run/5` — the loop everything above was
   leading to; internalize its four steps and the rest of the transform layer
   reads linearly.
5. `ImagePipe.Transform.NeutralResolver` — per-op lowering and the deferred-
   orientation policy, one `do_resolve/2` clause per plan op and one
   `continue/4` clause per measure tag.

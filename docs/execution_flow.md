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
            └─ Executor.run_neutral → NeutralResolver directly
               fixed neutral loop over PLAN operations:
               ├─ overlay shape → State                       (the one sync site)
               ├─ NeutralResolver.resolve → {executable_ops, continuation}
               ├─ ImagePipe.Transform.Chain.execute  ③        (materialize-if-needed + op.execute)
               └─ continuation                  ④
                    {:advance, shape, nil}  → next plan op
                    {:measure, tag, nil}    → measure dims → continue(tag, …), maybe more stages
   └─ encode (lazy) → Producer/PreparedStream: chunked streaming,
      cancellable on disconnect, incremental cache write → Response.Sender

ImagePipe.Plug.call (dialect: ImagePipe.Dialect.TwicPics)
└─ parse → ordered ImagePipe.Dialect.TwicPics.Request
└─ source identity, conditional request, and cache lookup
└─ fetch → decode → Dialect.TwicPics.Pipeline.run
   └─ literal Request.steps + pipeline-local PointFlow
└─ negotiate → encode → deliver
```

The framework path serves IIIF and host-supplied parsers. TwicPics mounts
through the same `ImagePipe.Plug` entry point via `dialect:`, but never enters
parser dispatch or constructs a root `ImagePipe.Plan`; its Pipeline and
PointFlow own positional execution. The framework step most readers get lost
in is the resolve loop, so the rest of this page is mostly about that path.

## The two operation vocabularies

There are two different kinds of "operation", and the neutral runtime-geometry
lowering (`NeutralResolver`) is the translator between them:

- **`ImagePipe.Plan.Operation.*`** — what framework parsers emit. Declarative,
  possibly deferred (`:auto` dims resolved against the source at runtime). These
  structs **never execute**.
- **`ImagePipe.Transform.Operation.*`** — executable: fully parameterized,
  every dimension concrete, every gravity a real point. These are what
  `Chain` runs, and one plan op may lower into several of them (a cover =
  a resize *then* a result crop).

When you are reading a `%Plan.Operation.Resize{}` and wondering "where do the
pixels happen" — they don't, until the selected executor driver lowers it.
TwicPics also reuses these semantic structs inside its ordered Request, but its
local Pipeline lowers them without passing through `Executor`.

## The resolve loop and continuations

For each pipeline, `Executor.execute` seeds a `SourceShape` — a pure geometry
value (dims, which frame they describe, pending orientation, decode shrink) —
and runs the fixed neutral driver `run_neutral/4`, which calls
`NeutralResolver.resolve/3` and `continue/4` directly. The loop:

1. **Overlay.** The neutral-advanced shape is written onto `State`
   (`pending_orientation`, `decode_shrink`, `source_dimensions`) — the single
   place shape and State sync.
2. **Resolve.** `NeutralResolver.resolve/3` returns the executable ops for this
   plan op plus a *continuation*.
3. **Execute.** The ops run through `Chain.execute` (which materializes to RAM
   first if an op requires random pixel access).
4. **Continue.** The continuation is plain data saying how to learn the
   post-op geometry:
   - `{:advance, new_shape, nil}` — the lowering computed it purely; move to
     the next plan op.
   - `{:measure, tag, nil}` — it can't be known without looking (after a
     trim; after a resize whose realized dims may round ±1). The driver
     measures the live image's dimensions and calls
     `NeutralResolver.continue(tag, {w, h}, shape, nil)` — `shape` being the
     pre-op shape the lowering resolved against — which returns either the final
     `{shape, nil}` or **another** `{ops, continuation}` stage to execute —
     that is how a cover emits its result crop parameterized against the
     *measured* post-resize dims. Recursion depth equals the emission's stage
     count (2 for a cover), never unbounded. Every tag is a named clause in
     `NeutralResolver.continue` — grep it for the full vocabulary
     (`:rotate`, `:trim`, `:resize`, `{:resize_tail, …}`,
     `{:resize_flush_tail, …}`).

The continuation is the only state channel: it is always `nil`-stated (the
neutral lowering carries no per-pipeline state), and the driver threads it into
the next resolve. A dialect that assembles its own ordered chain (imgproxy,
Native, TwicPics) calls these same `NeutralResolver` functions directly and
carries its own pipeline-local state — see the
[custom parser guide](custom_parser_guide.md#when-a-parser-isnt-enough).

At the pipeline boundary the driver flushes any surviving non-identity pending
orientation through an explicit `%Flush{}` (an identity pending is cleared
without materializing — the streaming fast path).

## Where "go to definition" stops working

The flow crosses a handful of dynamic-dispatch and injection points. Each is
deliberate (pluggability or test seams), and each has a short list of real
targets:

| # | Call site | What it dispatches to | How to navigate |
|---|---|---|---|
| ① | `parser.parse(conn, opts)` in `ImagePipe.Plug` | The mount's `:parser` module | The in-tree parser is `ImagePipe.Parser.IIIF`; hosts may supply another `ImagePipe.Parser`. TwicPics and imgproxy mount through `ImagePipe.Plug, dialect: …` and don't pass through this point |
| ③ | `chain.(state, ops, opts)` in `Executor` | Injected function; always `Chain.execute/3` in production | Test seam only. Inside `Chain`, `Transform.execute(op, state)` dispatches to the op struct's own module — struct name = module name (`%Operation.Crop{}` → `transform/operation/crop.ex`) |
| ④ | `continue(tag, …)` in `Executor` | `NeutralResolver.continue/4` | Tags are data: grep the tag atom (e.g. `:resize_flush_tail`) to land on both the emitting resolve row and the continue clause |
| — | `render: {:custom, module, params}` | The plan's renderer module via `ImagePipe.Renderer` | One in-tree renderer: IIIF's info renderer. `ImagePipe.Dialect.Imgproxy.InfoRenderer` supplies the `/info` terminal that the shared dialect runner (in `ImagePipe.Plug`) invokes via `{:render, %RenderTerminal{}}`, outside this `ImagePipe.Renderer` dispatch point |
| — | `Telemetry.span(…, fn -> … end)` wrappers | n/a | Nearly every layer wraps its real call in a span closure; when lost, skip to the closure body |

Also note `render: :image` vs custom renders fork early: a custom render
(info.json) runs no transform stage at all — `Runner` short-circuits to the
renderer with header facts only.

## Suggested reading order

1. `ImagePipe.Plug.do_call_with_plan/4` — the request skeleton and error fan-out.
2. `ImagePipe.Request.Processor.process_decoded_source/4` — decode → transform → encode hand-offs.
3. `ImagePipe.Transform.Executor.execute_pipeline/3` — shape seeding and the
   fixed neutral driver.
4. `ImagePipe.Transform.Executor.run_neutral/4` — the fixed neutral loop;
   internalize its four steps and the rest of the transform layer reads
   linearly.
5. `ImagePipe.Transform.NeutralResolver` — per-op lowering and the deferred-
   orientation policy, one `do_resolve/2` clause per plan op and one
   `continue/4` clause per measure tag.
6. `lib/image_pipe/dialect/twic_pics/pipeline.ex` and `point_flow.ex` — the
   separate ordered compatibility path.

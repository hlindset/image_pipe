# Execution flow

How a request actually moves through the code at runtime — the call spine, the
two operation vocabularies, the resolve loop, and the places where static
"go to definition" navigation stops working and what to do there. Read this
alongside the [custom dialect guide](custom_dialect_guide.md), which documents
the *contracts*; this page documents the *flow*.

## The call spine

One spine serves every request. `ImagePipe.Plug` reads the `:dialect` mount
option and hands everything else to `ImagePipe.Plug.DialectRunner`, which drives
the lifecycle and calls into the dialect at six points (marked ①–⑥).

```
ImagePipe.Plug.init
└─ dialect.validate_config!(opts)          ①  raises on invalid config; runs once

ImagePipe.Plug.call
└─ DialectRunner.run
   └─ [:request] span opens
   ├─ OPTIONS → 204 (CORS preflight) · non-GET/HEAD → 405 + Allow
   ├─ [:parse] span → dialect.parse(conn, config)   ②  → opaque request term
   │    {:redirect, status, location} → send and stop
   │    {:error, reason} → dialect.render_error/3
   ├─ dialect.prepare(conn, request, config)        ③  → %Dialect.Resolved{}
   ├─ ImagePipe.Source.resolve                          (source identity — no bytes yet)
   ├─ resolve Resolved.negotiation                      (deferred: a thunk, run after resolve)
   │    → %Dialect.Negotiation{} + %Representation.IdentityMaterial{}
   ├─ ImagePipe.Representation.build                    (cache key + ETag + Vary)
   ├─ cache-header policy
   │    http_cache: :generated      → Response.CachePolicy.generate
   │    http_cache: :dialect_owned  → CacheHeaders.from_representation
   ├─ conditional gate → 304                            (before any fetch/decode/encode/cache read)
   └─ terminal, from %Resolved{terminal:}
      ├─ :image
      │  └─ internal cache: hit → Sender streams the stored entry
      │     miss/disabled → Delivery.stream(build_fun)
      │        └─ ImagePipe.Decode.with_image           (fetch → decode bracket)
      │           └─ produce_stream:
      │              ├─ dialect.decode_request(request, geometry)   ④ shrink-on-load preflight
      │              ├─ [:transform, :execute] → dialect.execute    ⑤ the transform stage
      │              ├─ Output.Negotiate → Output.Clamp → Materializer
      │              └─ [:encode] first chunk → hand off to the pump
      │        → Sender streams the rest, writing the cache sink incrementally
      └─ {:render, %RenderTerminal{}}
         ├─ cache: :complete_body → cache hit serves the stored body;
         │                          miss runs the render fun and writes the entry
         └─ cache: :none          → run the render fun, deliver through Sender's
                                    offers-negotiated {:rendered, …} path
   └─ [:send] span wraps every terminal send, including errors
      dialect.render_error(conn, reason, config)        ⑥
```

Three properties of this spine shape everything:

- **The runner never names a dialect.** It branches only on
  `%ImagePipe.Dialect.Resolved{}` fields (`terminal`, `http_cache`, `debug?`,
  `auto_rotate?`) and on neutral core structs. A dialect-specific need that
  can't be expressed as a new `Resolved` value belongs in the dialect.
- **Negotiation is deferred and coupled.** `Resolved.negotiation` is either the
  result tuple or a zero-arity thunk producing it. The runner runs it only
  *after* `Source.resolve/3` succeeds, so source errors always beat negotiation
  errors, and the identity material (which every negotiation feeds) succeeds or
  fails with it.
- **The generated cache policy runs before the conditional gate.** Its
  suppression rules — a host `Set-Cookie`, `Vary: *`, a host `Cache-Control`, a
  source with no byte identity — must be able to veto the `304`.

## Who owns the transform stage

`dialect.execute/4` (⑤) is the fork between the two tiers:

- A **declarative** dialect (`use ImagePipe.Dialect.Declarative`) inherits
  `execute/4` from the base, which calls `Transform.execute_plan/3` →
  `ImagePipe.Transform.Executor` — the fixed neutral driver over the Plan's
  operations, described below.
- An **ordered** dialect (`ImagePipe.Dialect.Native`,
  `ImagePipe.Dialect.Imgproxy`, `ImagePipe.Dialect.TwicPics`) runs its own
  pipeline module (`Dialect.<Name>.Pipeline.run/4`) over its own request struct,
  calling `NeutralResolver` directly and carrying its own pipeline-local state.

Both wrap the run in `ImagePipe.Dialect.safe_transform/1`, which converts a
raise or throw from the libvips pipeline into `{:error, {:transform, _}}`. The
runner rescues nothing on a dialect's behalf.

## The two operation vocabularies

There are two different kinds of "operation", and the neutral runtime-geometry
lowering (`NeutralResolver`) is the translator between them:

- **`ImagePipe.Plan.Operation.*`** — declarative and possibly deferred (`:auto`
  dims resolved against the source at runtime). Both tiers speak this: a
  declarative dialect puts them in a `%Plan{}`, an ordered dialect carries them
  inside its own request struct. These structs **never execute**.
- **`ImagePipe.Transform.Operation.*`** — executable: fully parameterized,
  every dimension concrete, every gravity a real point. These are what `Chain`
  runs, and one plan op may lower into several of them (a cover = a resize
  *then* a result crop).

When you are reading a `%Plan.Operation.Resize{}` and wondering "where do the
pixels happen" — they don't, until a driver lowers it.

## The resolve loop and continuations

For each pipeline, `Executor.execute_pipeline/3` seeds a `SourceShape` — a pure
geometry value (dims, which frame they describe, pending orientation, decode
shrink) — and runs the fixed neutral driver `run_neutral/4`, which calls
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
the next resolve. An ordered dialect that assembles its own chain calls these
same `NeutralResolver` functions directly and carries its own pipeline-local
state — see the
[custom dialect guide](custom_dialect_guide.md#the-ordered-tier).

At the pipeline boundary the driver flushes any surviving non-identity pending
orientation through an explicit `%Flush{}` (an identity pending is cleared
without materializing — the streaming fast path).

## The input preambles

Two things run before any operation, and neither is an operation, because their
behavior comes entirely from the decoded image's own headers — data no operation
struct can see:

- **EXIF auto-orient.** Seeded into `State.pending_orientation` inside the
  decode bracket (`ImagePipe.Decode`), then flushed late, after crop/resize,
  with crop gravity and resize dimensions compensated into the storage frame.
- **Input color management.** The working-space import, seeded by
  `Executor` under the `seed_input_color_management` gate (which defaults to
  the `seed_orientation` gate). It has a required tail step,
  `InputColorManagement.stamp_carry/1` — the only writer of the headers the
  encoder's colorspace-to-result step reads. Every pipeline that runs the
  import must also run the stamp.

## Where "go to definition" stops working

The flow crosses a handful of dynamic-dispatch and injection points. Each is
deliberate (pluggability or test seams), and each has a short list of real
targets:

| # | Call site | What it dispatches to | How to navigate |
|---|---|---|---|
| ①–⑥ | `dialect.<callback>` in `DialectRunner` | The mount's `:dialect` module | In-tree: `ImagePipe.Dialect.Native`, `.Imgproxy`, `.TwicPics`, `.IIIF`. For a declarative dialect, five of the six land in `ImagePipe.Dialect.Declarative` (injected by its `__using__`), not in the dialect module |
| — | `chain.(state, ops, opts)` in `Executor` | Injected function; always `Chain.execute/3` in production | Test seam only. Inside `Chain`, `Transform.execute(op, state)` dispatches to the op struct's own module — struct name = module name (`%Operation.Crop{}` → `transform/operation/crop.ex`) |
| — | `continue(tag, …)` in `Executor` | `NeutralResolver.continue/4` | Tags are data: grep the tag atom (e.g. `:resize_flush_tail`) to land on both the emitting resolve row and the continue clause |
| — | `terminal.fun.(source, config)` in `DialectRunner` | The `%RenderTerminal{}`'s closure | Declarative dialects close over `ImagePipe.Renderer.run/3` (which owns the `[:render]` span) and the plan's `render: {:custom, module, params}` module — e.g. `ImagePipe.Dialect.IIIF.InfoRenderer`. Ordered dialects close over their own renderer (`ImagePipe.Dialect.Imgproxy.InfoRenderer`, the `ImagePipe.Dialect.Native` blur-hash terminal), bypassing that entry point |
| — | `Telemetry.span(…, fn -> … end)` wrappers | n/a | Nearly every layer wraps its real call in a span closure; when lost, skip to the closure body |

A render terminal runs no transform stage at all: the runner opens the decode
bracket only deep enough for header facts, and the renderer produces the whole
body.

## Suggested reading order

1. `ImagePipe.Plug.DialectRunner.run/3` and `handle_request/4` — the request
   skeleton and error fan-out.
2. `ImagePipe.Plug.DialectRunner.produce_stream/8` — decode → transform →
   negotiate → clamp → encode hand-offs, inside the delivery producer.
3. `ImagePipe.Dialect.Declarative` — how one `parse_plan/2` becomes the whole
   six-callback contract.
4. `ImagePipe.Transform.Executor.execute_pipeline/3` — shape seeding and the
   fixed neutral driver.
5. `ImagePipe.Transform.Executor.run_neutral/4` — the fixed neutral loop;
   internalize its four steps and the rest of the transform layer reads
   linearly.
6. `ImagePipe.Transform.NeutralResolver` — per-op lowering and the deferred-
   orientation policy, one `do_resolve/2` clause per plan op and one
   `continue/4` clause per measure tag.
7. `lib/image_pipe/dialect/twic_pics/pipeline.ex` and `point_flow.ex` — a
   compact ordered pipeline that carries its own positional state.

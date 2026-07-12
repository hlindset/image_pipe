# Writing a custom parser

A parser turns an incoming HTTP request into an `ImagePipe.Plan` — a
product-neutral, declarative description of *what* to produce: which source
image, which operations, and what output policy. Everything downstream
(fetching, decoding, transforming, encoding, caching, delivery) works from the
Plan and never sees your URL dialect.

This guide walks through every piece that can go into a compatibility parser,
from the minimum viable module to the advanced extension points:

- the `ImagePipe.Parser` behaviour and mounting (required)
- building Plans: sources, pipelines, operations, output (required)
- a geometry-resolution strategy via `ImagePipe.Resolver`, including custom
  carried state (optional)
- a custom terminal renderer via `ImagePipe.Renderer`, for non-image responses
  such as metadata JSON (optional)
- error rendering, redirects, testing, and repo conventions

The three in-tree parsers are worked examples at increasing levels of
sophistication:

| Parser | Dialect shape | Uses |
|---|---|---|
| `ImagePipe.Parser.TwicPics` | `?twic=v1/…` query chain | Custom resolver with carried state (focus point), directives |
| `ImagePipe.Parser.IIIF` | positional path grammar | Host-pluggable id resolution, 303 redirects, custom `info.json` renderer |
| `ImagePipe.Parser.Imgproxy` | signed path options | Signature validation, source-URL encryption, custom resolver, custom info renderer, presets |

When in doubt about a pattern, read the closest of these.

## The big picture

`ImagePipe.Plug` orchestrates a request roughly like this:

```
conn
 → parser.parse(conn, opts)          ← your code; produces %ImagePipe.Plan{}
 → plan validation                    (prefetch-safe shape checks)
 → ImagePipe.Source.resolve/3         (source identity, no bytes yet)
 → conditional-request evaluation     (ETag/304 — before any fetch)
 → fetch → decode → transform → encode (or serve from cache)
 → response delivery
```

Two properties of this flow shape everything a parser does:

- **Parsing is a pure translation step.** `parse/2` runs before any source
  fetch or cache access, so every parser-detected error (bad grammar, bad
  signature, expired request) is rejected without side effects. Keep it that
  way: a parser must not perform I/O.
- **URL option order must not define processing order.** The Plan is
  declarative; the transform layer owns operation semantics and a resolver
  strategy owns geometry decisions. A dialect whose syntax is order-sensitive
  (TwicPics) preserves order *within* its translation; a dialect whose syntax
  is order-insensitive (imgproxy) canonicalizes to a fixed operation order in
  its plan builder. Either way, the ordering decision is made once, at parse
  time, and recorded in the Plan.

## The parser behaviour

`ImagePipe.Parser` defines three callbacks:

```elixir
@callback parse(Plug.Conn.t(), keyword()) ::
            {:ok, ImagePipe.Plan.t()}
            | {:redirect, 303, String.t()}
            | {:error, any()}

@callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()

@callback validate_options!(opts :: keyword()) :: keyword()   # optional
```

### Mounting

A parser is any module passed as the `:parser` mount option — there is no
registry to enroll in:

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    parser: MyApp.Parser.Simple,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    simple: [auto_rotate: true]          # your parser's option namespace
  ]
```

`parse/2` receives the **full** mount option list, so a parser reads its own
configuration with `Keyword.fetch!(opts, :simple)` (or whatever namespace it
owns).

### Option validation: `validate_options!/1`

`ImagePipe.Plug.init/1` calls `ImagePipe.Parser.validate_options!/2`, which
dispatches to your `validate_options!/1` if you export it. It runs once at
mount time, so **raise** on invalid configuration rather than returning error
tuples. The convention:

1. Own exactly one top-level key, named after your dialect (`:iiif`,
   `:imgproxy`, `:twicpics`).
2. Split the options under that key into *neutral* keys (shared output/config
   surface — `ImagePipe.Config.keys/0`) and *dialect* keys (yours).
3. Validate dialect keys (NimbleOptions works well; see
   `ImagePipe.Parser.IIIF`), reject unknown keys, and resolve the neutral
   layer with `ImagePipe.Config.resolve!/2`.
4. Return the full option list with your namespace normalized in place —
   `parse/2` then reads pre-validated, fully-resolved config on every request.

`ImagePipe.Parser.TwicPics.validate_options!/1` is the minimal version of this
shape (no dialect keys at all); `ImagePipe.Parser.Imgproxy` shows a dialect
with real keys (signature secrets, source encryption, presets).

If a dialect deliberately supports only part of the neutral config surface,
declare the supported subset with `ImagePipe.Config.reject_unsupported!/3` so
unsupported host config fails at boot instead of being silently ignored.

### Errors and `handle_error/2`

When `parse/2` returns `{:error, reason}`, the plug hands the *same tuple* to
your `handle_error(conn, {:error, reason})`, and your parser owns the response
— status, content type, body. This is where dialect conventions live: imgproxy
returns `403` for signature failures and `400` for grammar errors; IIIF maps
`:not_found` to `404`. Keep bodies terse and non-reflective (don't echo
secrets or full URLs).

Only *parser* errors flow through `handle_error/2`. If a parser hands the plug
a structurally invalid Plan, the plug's own plan validation rejects it and
renders a generic plan error — you never see it. In practice you won't hit
that path: build operations through the `ImagePipe.Plan.Operation`
constructors and the Plan is valid by construction.

### Redirects

`parse/2` may return `{:redirect, 303, location}` and the plug sends the
redirect without further processing. `ImagePipe.Parser.IIIF` uses this for the
bare-identifier path (`/{id}` → `/{id}/info.json`), as the IIIF spec requires.

## Building the Plan

```elixir
%ImagePipe.Plan{
  source: ...,          # where the original bytes come from   (required)
  pipelines: [...],     # ordered operation groups             (required)
  output: ...,          # encode/negotiation policy            (required for render: :image)
  response: ...,        # delivery metadata (disposition, filename, debug?)
  expires: 0,           # unix-epoch request deadline; 0 = none
  cachebuster: nil,     # opaque token folded into the cache key
  auto_rotate: false,   # EXIF auto-orientation
  render: :image,       # terminal: :image | {:custom, module, params}
  resolver: nil         # geometry-resolution strategy; nil = neutral
}
```

### Sources

A parser translates the request's source reference into one of four
product-neutral `ImagePipe.Plan.Source` structs. These are **pure
identifiers** — the parser never fetches anything:

| Struct | Fields | Routed to |
|---|---|---|
| `Plan.Source.Path` | `segments` | the `:path` source adapter |
| `Plan.Source.URL` | `scheme` (`:http`/`:https`), `host`, `port`, `path`, `query` | the `:http` / `:https` adapter |
| `Plan.Source.Object` | `adapter`, `scope`, `key`, `revision` | `sources[adapter]` |
| `Plan.Source.Reference` | `adapter`, `id`, `revision`, `metadata` | `sources[adapter]` |

The `adapter:` atom on `Object`/`Reference` is a key into the host's `sources:`
mount option — that is the entire coupling between your parser and actual
fetching. Fetch behavior (`ImagePipe.Source` — `resolve/3`, `fetch/3`, byte
limits, redirect policy) is the *host's* contract, implemented by source
adapters, not by parsers.

If the dialect needs to resolve opaque identifiers to sources (IIIF's
`{identifier}`), make that pluggable the way `ImagePipe.Parser.IIIF.Resolver`
does: a small behaviour the host implements, configured through your option
namespace, returning a `Plan.Source` struct. If the dialect has its own source
URI scheme vocabulary (imgproxy's `s3://`, `local://`), follow
`ImagePipe.Parser.Imgproxy.Source`, which dispatches by scheme and supports
host-registered translators.

### Pipelines and operations

`pipelines:` is a list of `ImagePipe.Plan.Pipeline` structs, each an **ordered**
group of operation structs; groups execute in list order. Most dialects emit a
single pipeline:

```elixir
pipelines: [%ImagePipe.Plan.Pipeline{operations: ops}]
```

Operations are plain structs under `ImagePipe.Plan.Operation.*`, but never
build them by hand — use the validating constructors on
`ImagePipe.Plan.Operation`, which return `{:ok, op} | {:error, reason}` and
normalize as they build (angles folded into `[0, 360)`, floats converted to
exact ratios, unknown options rejected):

```elixir
{:ok, op} = Operation.resize(:fit, {:px, 300}, :auto)
{:ok, op} = Operation.crop_guided({:ratio, 1, 2}, :full_axis, :center)
{:ok, op} = Operation.blur(2.5)
```

The shared vocabulary you'll use everywhere:

- **Measures** — dimensions and positions are `{:px, n}` or an exact
  `{:ratio, numerator, denominator}`; resize/crop dims may also be `:auto` /
  `:full_axis`. Convert dialect sugar (percent, scale factors) with
  `ImagePipe.Plan.Measure` — never pass raw floats where a ratio is meant.
- **Colors** — `ImagePipe.Plan.Color` (`rgb/3`, `rgba/4`, `rgb_hex/1`) for
  backgrounds, fills, and effect colors.
- **Guides** — cropping/resizing operations take a `guide` describing where
  the crop gravitates: `:center`, nine anchor atoms, `{:anchor, h, v}`,
  `{:focal, x_ratio, y_ratio}`, `:smart` / `{:smart, :face_assist}`
  (saliency/face detection), `{:detect, {classes, weights}}` (object
  detection), or `:deferred` (resolved later by a custom resolver strategy —
  see below).

The operation vocabulary (resize, crop, canvas, padding, rotate/flip, trim,
color/effect ops, …) is documented in `docs/transform_operations.md`. The set
is **closed** from a parser's point of view: a parser maps its dialect onto
the existing semantic operations. If dialect syntax has no clean neutral
equivalent, your options are (a) a `Directive` consumed by your own resolver
strategy (below), or (b) proposing a new neutral operation in core — dialect
quirks must not leak product-specific semantics into the shared vocabulary.

One special operation exists purely for parsers with custom resolvers:
`Operation.directive(name, payload)` builds a `Plan.Operation.Directive`,
which performs **no pixel work**. It is a positional message to the plan's
resolver strategy (e.g. TwicPics' `:set_focus`). The payload is hashed into
the cache key as-is, so it must be canonical: the same request must always
produce the same term.

### Output

`ImagePipe.Plan.Output` describes the encode policy. The only decision most
parsers make per-request is the `mode`:

- `:automatic` — negotiate the output format from the `Accept` header and
  host policy.
- `{:explicit, format}` — the URL pinned a format (`:jpeg`, `:png`, `:webp`,
  `:avif`, `:jpeg_xl`), bypassing negotiation.

Optionally set `quality: {:quality, 1..100}` when the URL carries one. Then
stamp the host's resolved neutral config onto the struct:

```elixir
with {:ok, output} <- ImagePipe.Config.apply_to_output(%Output{mode: mode}, config) do
  ...
end
```

`apply_to_output/2` fills the config-owned fields (metadata stripping, color
profile policy, HDR handling, default qualities, autoquality search, encoder
options) from the resolved neutral config, so URL-level decisions and host
policy stay cleanly layered. Dialects that expose per-request autoquality
controls build the search with `ImagePipe.Plan.Output.QualitySearch.build/3`;
config-only dialects use `from_config/1` (and should probe it at boot in
`validate_options!/1`, as TwicPics does, so a bad host config fails at mount).

For a custom (non-image) terminal, `output` must be `nil` — see
[Custom renderers](#custom-renderers-non-image-terminals).

### Response, expires, cachebuster, auto_rotate

- `response:` — `ImagePipe.Plan.Response`: `disposition`
  (`:default | :inline | :attachment`), download `filename`, and `debug?`.
  `debug?` opts the request into `X-ImagePipe-*` debug headers when the host
  also mounted `allow_debug_headers: true`; it never affects bytes, cache key,
  or ETag.
- `expires:` — a unix-epoch deadline carried on the plan (0 = none).
  Enforcement is the parser's job at parse time: reject already-expired
  requests with an error (see `expires_plan` in the imgproxy plan builder).
- `cachebuster:` — an opaque string folded into the cache key (not the ETag),
  letting URL authors force a fresh cache entry for byte-identical plans.
- `auto_rotate:` — whether EXIF orientation is applied. Typically sourced
  from the resolved neutral config (`Keyword.fetch!(config, :auto_rotate)`).

## A minimal worked example

A complete parser for a toy query-string dialect —
`/{path...}?w=300&h=200&fmt=webp`:

```elixir
defmodule MyApp.Parser.Simple do
  @behaviour ImagePipe.Parser

  alias ImagePipe.Plan
  alias ImagePipe.Plan.{Operation, Output, Pipeline, Source}

  @impl ImagePipe.Parser
  def validate_options!(opts) do
    simple = Keyword.get(opts, :simple, [])

    {neutral, unknown} = Keyword.split(simple, ImagePipe.Config.keys())

    unless unknown == [] do
      raise ArgumentError, "unknown :simple keys #{inspect(Keyword.keys(unknown))}"
    end

    Keyword.put(opts, :simple, ImagePipe.Config.resolve!(neutral))
  end

  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    config = Keyword.fetch!(opts, :simple)
    params = Plug.Conn.fetch_query_params(conn).query_params

    with {:ok, source} <- source(conn.path_info),
         {:ok, ops} <- operations(params),
         {:ok, mode} <- format_mode(params["fmt"]),
         {:ok, output} <- ImagePipe.Config.apply_to_output(%Output{mode: mode}, config) do
      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: ops}],
         output: output,
         auto_rotate: Keyword.fetch!(config, :auto_rotate)
       }}
    end
  end

  @impl ImagePipe.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp source([]), do: {:error, :missing_source}
  defp source(segments), do: {:ok, %Source.Path{segments: segments}}

  defp operations(params) do
    with {:ok, w} <- dimension(params, "w"),
         {:ok, h} <- dimension(params, "h") do
      case {w, h} do
        {:auto, :auto} -> {:ok, []}
        {w, h} -> with {:ok, op} <- Operation.resize(:fit, w, h), do: {:ok, [op]}
      end
    end
  end

  defp dimension(params, key) do
    case Map.fetch(params, key) do
      :error ->
        {:ok, :auto}

      {:ok, value} ->
        case Integer.parse(value) do
          {px, ""} when px > 0 -> {:ok, {:px, px}}
          _ -> {:error, {:invalid_dimension, key, value}}
        end
    end
  end

  defp format_mode(nil), do: {:ok, :automatic}
  defp format_mode("jpeg"), do: {:ok, {:explicit, :jpeg}}
  defp format_mode("png"), do: {:ok, {:explicit, :png}}
  defp format_mode("webp"), do: {:ok, {:explicit, :webp}}
  defp format_mode("avif"), do: {:ok, {:explicit, :avif}}
  defp format_mode(other), do: {:error, {:invalid_format, other}}
end
```

In-tree parsers additionally split the work into submodules by concern —
`Path` (endpoint/source extraction), a grammar module (token parsing), and a
`PlanBuilder` (tokens → Plan) — all `@moduledoc false` except the top-level
parser module. Follow that layout once a parser grows past one file.

## Geometry resolution: custom resolver strategies

This is the deepest extension point. Skip it entirely if your dialect's
geometry is fully decidable at parse time — leave `resolver: nil` and the
built-in neutral strategy (`ImagePipe.Transform.NeutralResolver`) resolves
everything.

### Why resolvers exist

Some dialect semantics depend on the **source image's geometry**, which the
parser cannot know (parsing happens before any fetch). Examples:

- imgproxy's `rt:auto` picks fill-vs-fit by comparing source and target
  aspect orientation — decidable only once source dimensions are known.
- imgproxy's no-enlarge rule caps the DPR/padding scale by how much the
  source can actually shrink — computed at the resize, but *consumed* by
  later padding/canvas operations.
- TwicPics' `focus` sets a point that steers *subsequent* crops, and the
  point must be re-mapped through every geometry change between where it was
  set and where it is used.

A resolver strategy is a per-pipeline state machine that makes exactly these
runtime-geometry decisions. The parser selects it by setting `resolver:` on
the plan to a module implementing `ImagePipe.Resolver`:

```elixir
@callback init() :: strategy_state
@callback resolve(SourceShape.t(), strategy_state, plan_op :: struct()) ::
            {[executable_op :: struct()], continuation}
@callback behavior_version() :: pos_integer()
```

### The execution model

For each pipeline, the transform executor seeds an
`ImagePipe.Transform.SourceShape` — a pure geometry value (`width`, `height`,
which `frame` those dims describe, `pending_orientation`, `decode_shrink`) —
and creates fresh strategy state with `init/0`. The resolve driver then walks
the pipeline's plan operations one at a time:

1. It calls `resolve(shape, state, plan_op)`. Your strategy returns the
   **executable** transform operations to run for this plan op (lowered,
   fully-parameterized `ImagePipe.Transform.Operation.*` structs — every
   dimension concrete, every gravity a real point) plus a *continuation*.
2. The driver executes those ops, then follows the continuation:
   - `{:advance, new_shape, new_state}` — you computed the post-op geometry
     yourself (pure math); the driver moves on.
   - `{:acquire, then_fn}` — you can't know the post-op geometry without
     measuring (e.g. after a trim). The driver measures the realized
     dimensions of the live image and calls `then_fn.({w, h})`, which returns
     either the final `{shape, state}` or *another* `{ops, continuation}`
     stage to execute — a staged expansion for multi-step lowering.

**The continuation is the only channel for strategy state.** The driver never
inspects your state; it threads whatever you return into the next `resolve/3`
call. State is created fresh per pipeline and dies with it.

### Carried state, two patterns

Because most geometry math is shared, custom strategies **delegate** to
`ImagePipe.Transform.NeutralResolver` (whose strategy state is `nil`) and
layer their dialect decisions around it. Two in-tree patterns:

**Re-wrap the continuation** (imgproxy — carry computed values forward). The
strategy computes its cap once at the resize, stashes it in the carry, and
re-wraps every continuation the neutral resolver returns with
`ImagePipe.Resolver.rewrap/2`, which substitutes the carry through `:advance`,
through `:acquire`, and through every stage of a staged emission:

```elixir
defp delegate(operation, shape, carry) do
  {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)
  {ops, ImagePipe.Resolver.rewrap(continuation, carry)}
end
```

Always route delegation through `rewrap/2`: a continuation returned unmodified
carries the neutral resolver's `nil` state, which would replace your carry at
the first `:advance`.

**Advance a carried point through emitted ops** (TwicPics — state that must
track geometry). The focus point set by a `Directive` must stay meaningful as
crops and resizes change the coordinate space, so the strategy walks the
emitted executable ops and re-maps the point through each one:

```elixir
@impl ImagePipe.Resolver
def init, do: nil

@impl ImagePipe.Resolver
def resolve(%SourceShape{} = shape, _point, %Directive{name: :set_focus, payload: operand}) do
  resolved = Focus.resolve(operand, ..., shape.pending_orientation)
  {[], {:advance, shape, resolved}}       # emit nothing; update the carry
end

def resolve(%SourceShape{} = shape, point, operation) do
  {ops, continuation} = NeutralResolver.resolve(shape, nil, operation)
  PointFlow.advance(ops, continuation, point, shape)
end
```

`ImagePipe.Parser.TwicPics.Resolver` (with its `PointFlow` helper) is the
cleanest full example of a carried-state strategy and the best template to
start from.

### Dialect vocabulary: deferred markers and directives

A strategy and its parser share a private vocabulary that the neutral column
never sees. The pieces available:

- **`:deferred` guides** — `Operation.Resize` and `Operation.CropGuided`
  accept `guide: :deferred`, meaning "a point-carrying resolver strategy will
  substitute a concrete point before emission".
- **`Operation.Directive`** — a no-pixel message positioned in the operation
  stream, consumed by your strategy (`:set_focus` above). Emitting a
  `Directive` your resolver has no clause for is a programmer error.
- **Dialect-specific field markers** — e.g. `Operation.Resize` `mode: :auto`
  and `Operation.Padding` `pixel_ratio: {:effective, ratio, mode}` exist for
  the imgproxy strategy, which resolves them to concrete values *before*
  delegating; the neutral resolver never sees them. If your dialect needs a
  new marker of this kind, it is a core change — the marker lives on a shared
  Plan struct — so keep the pairing rule in mind: every marker a parser can
  emit must have exactly one strategy that resolves it.

Plan validation enforces the resolver half of that pairing: a plan carrying
any strategy-requiring vocabulary (a `:deferred` guide, a `Directive`, an
`:auto` resize mode, an `{:effective, …}` padding scale) with `resolver: nil`
is rejected at the plan boundary as `{:strategy_required, operation}` instead
of erroring deep in the transform stage.

### The strategy SDK

A strategy builds against a deliberately small, stable surface — the "strategy
SDK" tier of the Transform boundary's exports:

- `ImagePipe.Resolver` — the behaviour, plus `rewrap/2` for carry-preserving
  delegation.
- `ImagePipe.Transform.SourceShape` — the shape value and its pure helpers
  (`seed/1`, `live_dims/1`, `quarter_turn?/1`).
- `ImagePipe.Transform.NeutralResolver` — the delegate (`resolve/3`) and its
  two advance helpers (`display_frame_advance/2`, `plain_advance/2`) for
  composing your own lowering with the neutral orientation-flush policy.
- `ImagePipe.Transform.Focus` and `ImagePipe.Transform.PendingOrientation` —
  point and orientation geometry for carried-point strategies.
- The executable `ImagePipe.Transform.Operation.*` structs a strategy emits,
  including their pure geometry helpers (`Crop.resolved_rect/3`,
  `ExtendCanvas.resolved_canvas_dims/3`, `Resize.resolve_dimensions/2`) —
  advance a carried value with these rather than re-deriving geometry.

`ImagePipe.Transform.Lowering` and `ImagePipe.Transform.ResizePlanning` are
**not** part of this contract: they are internal lowering seams, exported only
for the in-tree imgproxy strategy, and may change without notice. A strategy
outside this repository should not build on them.

### `behavior_version/0` and caching

The strategy module and its `behavior_version/0` enter the cache key and ETag
material. Whenever you change a resolution rule your strategy owns — anything
that could produce different bytes for the same plan — bump
`behavior_version/0`. Otherwise clients holding an old ETag can revalidate
stale, differently-resolved bytes forever.

## Custom renderers (non-image terminals)

Some dialect endpoints return something other than an encoded image — IIIF's
`info.json`, imgproxy's `/info`. For those, implement `ImagePipe.Renderer`:

```elixir
@callback requires(params :: map()) :: [:header]
@callback render(RenderContext.t(), params :: map(), keyword()) ::
            {:ok, {content_type :: String.t(), iodata()}} | {:error, term()}
```

and select it on the plan:

```elixir
%Plan{
  source: source,
  pipelines: [],
  output: nil,                                # custom renders carry no image output
  render: {:custom, MyParser.InfoRenderer, %{}}
}
```

`requires/1` declares which expensive pipeline stages the renderer needs
(currently `:header` — decoded header facts). `render/3` receives an
`ImagePipe.Plan.RenderContext` whose `info` is a `ImagePipe.Plan.SourceInfo`
(format, dimensions, orientation, byte size) and returns the complete response
body. Plan validation enforces the pairing: `render: :image` requires an
`%Output{}`; a custom render requires `output: nil`. See
`ImagePipe.Parser.IIIF.InfoRenderer` for a complete example.

## Testing a parser

Follow the two-tier layout the in-tree parsers use:

- **Unit tests** in `test/parser/<dialect>/` — grammar, path/endpoint
  classification, plan building, option validation. Assert on the Plans and
  operations your parser produces. StreamData property tests earn their keep
  for order-insensitivity, unit conversion, and canonicalization invariants.
- **Wire-level tests** in `test/image_pipe/` — a compact, representative set
  of real `ImagePipe.call/2` requests asserting user-visible contracts:
  status codes, content types, decoded output dimensions, `Vary`/negotiation,
  error statuses from `handle_error/2`, and that request-safety failures
  (bad grammar, bad signature) return **before** any source or cache access.
  See `test/image_pipe/twic_pics_wire_conformance_test.exs` for shape and
  scale — keep combinatorial grammar coverage in the unit tier.
- **Resolver tests** in `test/image_pipe/parser/<dialect>/resolver_test.exs`
  if you ship a strategy — drive `resolve/3` directly with `SourceShape`
  values and assert emitted executables, continuations, and carry survival
  across `:acquire`.

## Conventions checklist

Beyond the code itself, a new in-tree parser should:

- **Declare its boundary.** `use Boundary` on the top-level parser module;
  parsers may depend on `ImagePipe.Parser`, `ImagePipe.Plan`,
  `ImagePipe.Renderer`, `ImagePipe.Resolver`, and `ImagePipe.Transform`.
  Export nothing unless the host must call it (imgproxy exports its
  source-scheme behaviour).
- **Ship a conformance doc.** Each compatibility target gets
  `docs/<target>_support_matrix.md` documenting the supported surface,
  processing-stage mapping, and deliberate divergences — and that doc must be
  updated in the same change as any parity-affecting behavior change.
- **Register docs.** Add the support matrix (and any companion docs) to the
  ExDoc `extras` in `mix.exs`. Modules under `ImagePipe.Parser.*` are grouped
  under "Parser API" automatically.
- **Keep the demo in sync.** The fiddle app (`fiddle/assets/`) should be able
  to exercise the parser's options end-to-end when the parser is meant to be
  demoable.

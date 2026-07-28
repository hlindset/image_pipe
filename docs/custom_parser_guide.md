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
- a custom terminal renderer via `ImagePipe.Renderer`, for non-image responses
  such as metadata JSON (optional)
- error rendering, redirects, testing, and repo conventions

A host `ImagePipe.Parser` produces only product-neutral declarative Plans. If a
dialect's meaning depends on the *order* of its operations or on running-image
geometry it carries across steps (positional focus, running-dimension units),
it is not a declarative parser: it implements the `ImagePipe.Dialect`
behaviour, mounted via `ImagePipe.Plug, dialect: …`, and owns its own
pipeline. See [When a parser isn't enough](#when-a-parser-isnt-enough).

The in-tree framework parser is the primary worked example:

| Parser | Dialect shape | Uses |
|---|---|---|
| `ImagePipe.Parser.IIIF` | positional path grammar | Host-pluggable id resolution, 303 redirects, custom `info.json` renderer |

For signed path options, source-URL encryption, presets, or syntax whose order
is itself the execution model, use an `ImagePipe.Dialect` implementation
(mounted via `ImagePipe.Plug, dialect: …`) as the architectural reference.
`ImagePipe.Dialect.Imgproxy` and `ImagePipe.Dialect.TwicPics` don't implement
`ImagePipe.Parser`.

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
  declarative; the transform layer owns operation semantics and neutral
  runtime-geometry lowering. Map matching URL spellings into the same Plan. If
  the syntax requires a positional command stream that can't be stated as a
  declarative Plan, it belongs in an `ImagePipe.Dialect` implementation
  (mounted via `ImagePipe.Plug, dialect: …`), not a parser.

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

1. Own exactly one top-level key, named after your parser (`:iiif`, `:simple`).
2. Split the options under that key into *neutral* keys (shared output/config
   surface — `ImagePipe.Config.keys/0`) and *dialect* keys (yours).
3. Validate dialect keys (NimbleOptions works well; see
   `ImagePipe.Parser.IIIF`), reject unknown keys, and resolve the neutral
   layer with `ImagePipe.Config.resolve!/2`.
4. Return the full option list with your namespace normalized in place —
   `parse/2` then reads pre-validated, fully-resolved config on every request.

`ImagePipe.Parser.IIIF` shows the complete shape: an id resolver, supported
formats and qualities, tile size, and maximum dimensions.

If a dialect deliberately supports only part of the neutral config surface,
declare the supported subset with `ImagePipe.Config.reject_unsupported!/3` so
unsupported host config fails at boot instead of being silently ignored.

### Errors and `handle_error/2`

When `parse/2` returns `{:error, reason}`, the plug hands the *same tuple* to
your `handle_error(conn, {:error, reason})`, and your parser owns the response
— status, content type, body. This is where dialect conventions live: IIIF
maps `:not_found` to `404`. (`ImagePipe.Dialect.Imgproxy`, which implements
the `ImagePipe.Dialect` behaviour's `render_error/3` callback rather than
`ImagePipe.Parser`, uses an analogous convention in `Dialect.Imgproxy.Errors`
— 403 for signature failures, 400 for grammar errors.) Keep bodies terse and
non-reflective (don't echo secrets or full URLs).

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
  render: :image        # terminal: :image | {:custom, module, params}
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
URI scheme vocabulary, keep that translation in the parser and expose a
host-facing translator behaviour. `ImagePipe.Dialect.Imgproxy.SourceScheme`
shows the public callback: `translate(String.t(), keyword())` returns
`{:ok, Plan.Source.t()} | {:error, term()}`.

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
  (saliency/face detection), or `{:detect, {classes, weights}}` (object
  detection). Runtime-geometry guides like `:smart`/`{:detect, …}` are resolved
  by the neutral runtime-geometry lowering; a parser just names the guide.

The operation vocabulary (resize, crop, canvas, padding, rotate/flip, trim,
color/effect ops, …) is documented in `docs/transform_operations.md`. The set
is **closed** from a parser's point of view: a parser maps its dialect onto
the existing semantic operations. If dialect syntax has no clean neutral
equivalent, propose a new neutral operation in core — dialect quirks must not
leak product-specific semantics into the shared vocabulary. If the quirk is an
*ordered* runtime-geometry behavior that has no product-neutral statement, it
belongs in an `ImagePipe.Dialect` implementation, not the declarative Plan
(see [When a parser isn't enough](#when-a-parser-isnt-enough)).

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
config-only parsers use `from_config/1` and should probe it at boot in
`validate_options!/1` so a bad host config fails at mount.

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

## When a parser isn't enough

`ImagePipe.Parser` produces a **product-neutral declarative Plan**. That is the
whole contract: which source, which semantic operations, what output policy.
Everything runtime-geometry-dependent — the `:auto` fill-vs-fit resize rule, a
`:smart`/`{:detect, …}` crop window, the deferred EXIF-orientation flush — is
resolved by the core's fixed neutral runtime-geometry lowering
(`ImagePipe.Transform.NeutralResolver`), which every Plan runs through. A parser
never carries a geometry-resolution strategy and never sees executable
transform operations.

Some dialects can't be expressed this way. When a dialect's meaning depends on
the **order** of its operations, or it carries state across operations against
the **running image geometry** — positional focus that later crops consume,
relative units (`p`/`s`) resolved against the dimensions produced by preceding
operations — a declarative option bag would erase the behavior. Those dialects
are **not** host parsers: they own their ordered request model and their own
pipeline. `ImagePipe.Dialect.Imgproxy`, `ImagePipe.Dialect.Native`, and
`ImagePipe.Dialect.TwicPics` are the in-tree examples; they don't implement
`ImagePipe.Parser` and don't construct a root `ImagePipe.Plan`.

An ordered dialect implements the public `ImagePipe.Dialect` behaviour — one
callback per lifecycle phase (config validation, parse, prepare, decode
preflight, transform execution, error rendering) — and mounts through the
shared runner: `plug ImagePipe.Plug, dialect: MyDialect, <flat config>`. The
runner owns the neutral request lifecycle (source resolution, conditional
GET, cache serve, streaming delivery); the dialect owns everything
dialect-specific as values on `ImagePipe.Dialect.Resolved`.
All three in-tree ordered dialects — `ImagePipe.Dialect.Native`,
`ImagePipe.Dialect.Imgproxy`, and `ImagePipe.Dialect.TwicPics` — implement
this contract and mount through `ImagePipe.Plug, dialect: …`. IIIF remains on
the framework `parser:` mount until Phase C. A dialect
reuses neutral core boundaries (`Decode`, `Output`, `Source`, `Transform`, …)
and neutral Plan operation structs as semantic inputs, but it must not depend
on private in-tree implementation helpers such as
`ImagePipe.Transform.Lowering` or `ImagePipe.Transform.ResizePlanning` — those
are internal seams for the in-tree dialect Pipelines and may change without
notice.

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
  See `test/parser/iiif_wire_test.exs` for shape and scale — keep combinatorial
  grammar coverage in the unit tier.

## Conventions checklist

Beyond the code itself, a new in-tree parser should:

- **Declare its boundary.** `use Boundary` on the top-level parser module;
  parsers may depend on `ImagePipe.Parser`, `ImagePipe.Plan`,
  `ImagePipe.Renderer`, and `ImagePipe.Transform`. Export nothing unless the
  host must implement a callback the parser calls (e.g. an id resolver).
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

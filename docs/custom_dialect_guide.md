# Writing a custom dialect

A **dialect** is the module that turns an incoming HTTP request into work
ImagePipe knows how to do. It owns the URL grammar, the configuration surface,
and the error vocabulary; the shared runner owns the request lifecycle around
it — source resolution, representation identity, conditional `GET`, caching,
streaming delivery.

Every request stack is a dialect, and every dialect uses one mount shape:

```elixir
plug ImagePipe.Plug, dialect: MyApp.Dialect, sources: [...]
```

`ImagePipe.Plug` reads only `:dialect`; everything else in the list is the
dialect's own flat config, handed to its `c:ImagePipe.Dialect.validate_config!/1`
at init.

Dialects come in two tiers:

| Tier | You implement | Transform stage | In-tree |
|---|---|---|---|
| **Declarative** | `parse_plan/2` → `%ImagePipe.Plan{}` | the fixed neutral driver, from the base | `ImagePipe.Dialect.IIIF` |
| **Ordered** | the full `ImagePipe.Dialect` behaviour | your own pipeline, in `execute/4` | `ImagePipe.Dialect.Native`, `ImagePipe.Dialect.Imgproxy`, `ImagePipe.Dialect.TwicPics` |

One lifecycle covers both. Same behaviour, same runner, same mount — the runner
never branches on which tier produced its `%ImagePipe.Dialect.Resolved{}`. The
only difference is who owns the transform stage.

**Start declarative.** Reach for the ordered tier only when the dialect's
meaning depends on the *order* of its operations, or when it carries state
across operations against the *running* image geometry — positional focus a
later crop consumes, relative units resolved against the dimensions a preceding
operation produced. A declarative option bag would erase those behaviors.
Everything else — including a positional path grammar like IIIF's — is
declarative.

## The lifecycle

The shared runner (`ImagePipe.Plug.DialectRunner`) drives every request through
the same spine, calling into the dialect at six points:

```
init      → validate_config!(config)                        (raises on bad config)

call      → [:request] span
            OPTIONS → 204 · non-GET/HEAD → 405
            [:parse] span → parse(conn, config)             ← your grammar
            prepare(conn, request, config) → %Resolved{}    ← gates, source, terminal
            ImagePipe.Source.resolve                        (identity, no bytes yet)
            resolve the deferred negotiation → identity material
            ImagePipe.Representation.build                  (cache key + ETag)
            cache-header policy                             (http_cache: :generated only)
            conditional gate → 304                          (before any fetch/decode/cache read)
            terminal:
              :image     → decode bracket → decode_request/2 → execute/4 → encode → stream
              {:render, %RenderTerminal{}} → the render fun's complete body
            [:send] span
```

Two properties shape everything a dialect does:

- **Parsing is a pure translation step.** `parse/2` runs before any source
  fetch or cache access, so every parse-detected error (bad grammar, bad
  signature, expired request) is rejected without side effects. Keep it that
  way: `parse/2` must not perform I/O.
- **The dialect never sees the runner's internals.** Everything a dialect
  decides rides `%ImagePipe.Dialect.Resolved{}` as *values*. The runner branches
  only on those fields and on neutral core structs, and never names a dialect.

## The declarative tier

`use ImagePipe.Dialect.Declarative` injects `parse/2`, `prepare/3`,
`decode_request/2`, and `execute/4` for you, plus a default `classify_error/1`.
You supply `parse_plan/2`, `render_error/3`, and `validate_config!/1`:

```elixir
defmodule MyApp.Dialect do
  use ImagePipe.Dialect.Declarative

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: MyApp.Dialect.Config.validate!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, config) do
    {:ok, %ImagePipe.Plan{...}}
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: MyApp.Dialect.Errors.send(conn, reason, config)
end
```

`parse_plan/2` returns `{:ok, %Plan{}}`, `{:redirect, status, location}`, or
`{:error, reason}`. The base wraps it in the behaviour's `parse/2`, owns the
`[:parse]` span's stop metadata, drives the fixed neutral transform driver in
`execute/4`, and derives the representation identity from the Plan.

`classify_error/1` is injected with a sensible default and is `defoverridable`;
an override must re-declare `@impl ImagePipe.Dialect`.

A `{:redirect, status, location}` result sends the redirect without further
processing. `ImagePipe.Dialect.IIIF` uses it for the bare-identifier path
(`/{id}` → 303 to `/{id}/info.json`), as the IIIF spec requires.

### What `render_error/3` receives

A parse rejection arrives wrapped as
`%ImagePipe.Dialect.Failure{phase: :parse, reason: your_reason}`; every other
lifecycle failure arrives as a bare reason. Match the wrapper so an
*unrecognized* parse rejection still renders as a client error, without
inferring provenance from a tag allowlist:

```elixir
def send(conn, %Failure{phase: :parse, reason: :not_found}, _config),
  do: text(conn, 404, "not found")

def send(conn, %Failure{phase: :parse}, _config),
  do: text(conn, 400, "bad request")

def send(conn, reason, config) do
  {status, message} = ImagePipe.Response.ErrorStatus.resolve_status(reason, config)
  text(conn, status, message)
end
```

Everything past parse should route through `ImagePipe.Response.ErrorStatus`,
the shared reason → status/message table, with the core-stage re-tagging every
dialect performs: a transform failure becomes `{:transform_error, _}` (422) and
a materialization failure becomes `{:decode, _}` (415). Keep bodies terse and
non-reflective — never echo a signature or a full source URL.
`ImagePipe.Dialect.IIIF.Errors` is the worked example.

### The config split

Configuration is one flat keyword list. Your `validate_config!/1` splits it into four
layers and validates each with the layer that owns it —
`ImagePipe.Dialect.IIIF.Config` is the reference:

```elixir
def validate!(opts) when is_list(opts) do
  {shared, rest} = Keyword.split(opts, ImagePipe.Dialect.SharedConfig.keys())
  {base, rest} = Keyword.split(rest, ImagePipe.Dialect.Declarative.config_keys())
  {neutral, rest} = Keyword.split(rest, ImagePipe.Config.keys())
  {dialect, unknown} = Keyword.split(rest, @dialect_keys)

  reject_unknown!(unknown)

  shared
  |> ImagePipe.Dialect.SharedConfig.validate_runtime!()
  |> Keyword.merge(ImagePipe.Dialect.Declarative.validate_config!(base))
  |> Keyword.merge(validate_neutral!(neutral))
  |> Keyword.merge(validate_dialect!(dialect))
end
```

| Layer | Owner | Contents |
|---|---|---|
| Shared runtime | `ImagePipe.Dialect.SharedConfig.keys/0` | `:sources`, `:cache`, `:max_body_bytes`, `:max_input_pixels`, `:max_result_width`/`:max_result_height`/`:max_result_pixels`, `:telemetry_prefix`, `:auto_avif`/`:auto_webp`/`:auto_jpeg_xl`, `:format_order`, `:output_capabilities`, `:allow_origin`, `:allow_debug_headers` |
| Declarative base | `ImagePipe.Dialect.Declarative.config_keys/0` | `:http_cache`, `:detector`, `:detector_required`, `:storage_inputs` |
| Neutral output | `ImagePipe.Config.keys/0` | encode policy: qualities, metadata stripping, color-profile policy, HDR, per-format encoder options, the autoquality knobs, `:auto_rotate` |
| Yours | your own schema | the dialect's own surface |

Validation runs once, at mount time, so **raise** on invalid configuration
rather than returning error tuples. The runner reads the shared runtime keys
straight from the validated list, so delegate that subset to `SharedConfig`
rather than hand-rolling those keys. `NimbleOptions` works well for the rest;
reject unknown keys outright. If your dialect deliberately supports only part
of the neutral surface, declare the supported subset with
`ImagePipe.Config.reject_unsupported!/3` so unsupported host config fails at
boot instead of being silently ignored.

### HTTP cache headers are opt-in

A declarative dialect's `%Resolved{}` carries `http_cache: :generated`, which
runs `ImagePipe.Response.CachePolicy` between building the representation and
the conditional gate. The policy generates **nothing** unless the mount also
sets:

```elixir
http_cache: [mode: :enabled]
```

Without it, no generated `ETag` and no generated `Cache-Control` are emitted at
all. This is an asymmetry worth knowing: the ordered dialects are
`http_cache: :dialect_owned` and always stamp the representation's own `ETag`
straight from `ImagePipe.Representation.response_headers/1`. See
[CDN HTTP caching](cdn-http-cache.md) for the full policy, its suppression
rules, and the per-source override.

### Storage partitioning

`storage_inputs: [{:header, "x-tenant"}, {:cookie, "session"}]` folds the named
request values into the **cache key** without changing the ETag — they
partition storage, not bytes. Configured header names also enter `Vary`
(cookies never do; `Vary` names headers only).

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

The declarative tier doesn't enforce `expires`. A dialect that needs
request expiry rejects expired requests itself, inside `parse_plan/2`.

### Sources

Translate the request's source reference into one of four product-neutral
`ImagePipe.Plan.Source` structs. These are **pure identifiers** — a dialect
never fetches anything:

| Struct | Fields | Routed to |
|---|---|---|
| `Plan.Source.Path` | `segments` | the `:path` source adapter |
| `Plan.Source.URL` | `scheme` (`:http`/`:https`), `host`, `port`, `path`, `query` | the `:http` / `:https` adapter |
| `Plan.Source.Object` | `adapter`, `scope`, `key`, `revision` | `sources[adapter]` |
| `Plan.Source.Reference` | `adapter`, `id`, `revision`, `metadata` | `sources[adapter]` |

The `adapter:` atom on `Object`/`Reference` is a key into the host's `sources:`
mount option — that is the entire coupling between a dialect and actual
fetching. Fetch behavior (`ImagePipe.Source` — `resolve/3`, `fetch/3`, byte
limits, redirect policy) is the *host's* contract, implemented by source
adapters.

If the dialect resolves opaque identifiers to sources (IIIF's `{identifier}`),
make that pluggable the way `ImagePipe.Dialect.IIIF.Resolver` does: a small
behaviour the host implements, configured through your options, returning a
`Plan.Source` struct. If the dialect has its own source-URI scheme vocabulary,
expose a host-facing translator behaviour instead;
`ImagePipe.Dialect.Imgproxy.SourceScheme` shows the public callback —
`translate(String.t(), keyword())` returning
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
  by the neutral runtime-geometry lowering; a dialect just names the guide.

The operation vocabulary (resize, crop, canvas, padding, rotate/flip, trim,
color/effect ops, …) is documented in
[transform operations](transform_operations.md). The set is **closed** from a
dialect's point of view: map your syntax onto the existing semantic operations.
If dialect syntax has no clean neutral equivalent, propose a new neutral
operation in core — dialect quirks must not leak product-specific semantics
into the shared vocabulary.

Everything runtime-geometry-dependent — the `:auto` fill-vs-fit resize rule, a
`:smart`/`{:detect, …}` crop window, the deferred EXIF-orientation flush — is
resolved by the neutral runtime-geometry lowering
(`ImagePipe.Transform.NeutralResolver`), which every Plan runs through. No
dialect carries a geometry-resolution strategy of its own.

### Output

`ImagePipe.Plan.Output` describes the encode policy. The only decision most
dialects make per request is the `mode`:

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
config-only dialects use `from_config/1` and should probe it at boot in
`validate_config!/1` so a bad host config fails at mount.

For a custom (non-image) terminal, `output` must be `nil` — see
[Render terminals](#render-terminals-non-image-responses).

### Response, cachebuster, auto_rotate

- `response:` — `ImagePipe.Plan.Response`: `disposition`
  (`:default | :inline | :attachment`), download `filename`, and `debug?`.
  `debug?` opts the request into `X-ImagePipe-*` debug headers when the host
  also mounted `allow_debug_headers: true`; it never affects bytes, cache key,
  or ETag.
- `cachebuster:` — an opaque string folded into the cache key (not the ETag),
  letting URL authors force a fresh cache entry for byte-identical plans.
- `auto_rotate:` — whether EXIF orientation is applied. Typically sourced
  from the resolved neutral config (`Keyword.fetch!(config, :auto_rotate)`).

## A minimal worked example

A complete declarative dialect for a toy query-string grammar —
`/{path...}?w=300&h=200&fmt=webp`:

```elixir
defmodule MyApp.Dialect.Simple do
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Plan
  alias ImagePipe.Plan.{Operation, Output, Pipeline, Source}

  @impl ImagePipe.Dialect
  def validate_config!(opts) do
    {shared, rest} = Keyword.split(opts, ImagePipe.Dialect.SharedConfig.keys())
    {base, rest} = Keyword.split(rest, ImagePipe.Dialect.Declarative.config_keys())
    {neutral, unknown} = Keyword.split(rest, ImagePipe.Config.keys())

    unless unknown == [] do
      raise ArgumentError, "unknown option(s): #{inspect(Keyword.keys(unknown))}"
    end

    shared
    |> ImagePipe.Dialect.SharedConfig.validate_runtime!()
    |> Keyword.merge(ImagePipe.Dialect.Declarative.validate_config!(base))
    |> Keyword.merge(ImagePipe.Config.resolve!(neutral))
  end

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, config) do
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

  @impl ImagePipe.Dialect
  def render_error(%Plug.Conn{} = conn, %Failure{phase: :parse, reason: reason}, _config) do
    text(conn, 400, "invalid image request: #{inspect(reason)}")
  end

  def render_error(%Plug.Conn{} = conn, reason, config) do
    {status, message} = ImagePipe.Response.ErrorStatus.resolve_status(reason, config)
    text(conn, status, message)
  end

  defp text(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(status, body)
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

Mount it:

```elixir
forward "/images",
  to: ImagePipe.Plug,
  init_opts: [
    dialect: MyApp.Dialect.Simple,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    http_cache: [mode: :enabled]
  ]
```

In-tree dialects split the work into submodules by concern — `Path`
(endpoint/source extraction), a `Grammar` module (token parsing), a
`PlanBuilder` (tokens → Plan), a `Config`, and an `Errors` — all
`@moduledoc false` except the top-level dialect module. Follow that layout once
a dialect grows past one file.

## The ordered tier

An ordered dialect implements all six `ImagePipe.Dialect` callbacks itself and
owns its transform stage:

```elixir
@callback validate_config!(config) :: config
@callback parse(Plug.Conn.t(), config) :: {parse_result, span_stop_metadata :: map()}
@callback prepare(Plug.Conn.t(), request, config) :: {:ok, Resolved.t()} | {:error, term()}
@callback decode_request(request, SourceGeometry.t()) :: DecodePlanner.Request.t()
@callback execute(State.t(), SourceGeometry.t(), request, keyword()) ::
            {:ok, State.t()} | {:error, term()}
@callback render_error(Plug.Conn.t(), reason :: term(), config) :: Plug.Conn.t()
```

One callback per lifecycle phase, never a mid-execution hook. `request` is
opaque to the runner: it is whatever struct your `parse/2` produced.

`ImagePipe.Dialect.TwicPics` is the compact reference. Its `parse/2` returns its
own `Request` struct paired with the `[:parse]` span's stop metadata; its
`prepare/3` returns a `%Resolved{}` with `http_cache: :dialect_owned` and a
deferred negotiation thunk; its `execute/4` runs the dialect's own ordered
`Pipeline` and `PointFlow`.

`execute/4` is the ordering boundary. The runner rescues nothing on a dialect's
behalf, so wrap the pipeline run in `ImagePipe.Dialect.safe_transform/1`, which
converts a raise or throw out of the libvips pipeline into the callback's
tagged-tuple contract as `{:error, {:transform, _}}`:

```elixir
@impl ImagePipe.Dialect
def execute(state, geometry, %Request{} = request, opts) do
  ImagePipe.Dialect.safe_transform(fn -> Pipeline.run(state, geometry, request, opts) end)
end
```

An ordered dialect still emits the neutral `ImagePipe.Plan.Operation.*` structs
and lowers them through `ImagePipe.Transform.NeutralResolver` — every
source-dependent geometry decision stays in the neutral column. What it never does is
construct a root `%ImagePipe.Plan{}`.

An ordered dialect also builds its own identity material (its `Identity`
module) and, if it has a non-image endpoint, drives its own `RenderTerminal`
fun rather than `ImagePipe.Renderer.run/3`.

## Render terminals (non-image responses)

Some endpoints return something other than an encoded image — the IIIF
`info.json`, the imgproxy `/info`, a blur-hash placeholder. `%Resolved{}` selects one
with `terminal: {:render, %ImagePipe.Dialect.RenderTerminal{}}`:

```elixir
%ImagePipe.Dialect.RenderTerminal{
  fun: fn resolved_source, config -> {:ok, content_type, body} end,
  cache: :complete_body,   # or :none
  offers: [],              # [{content_type, [accept_token]}] — only with cache: :none
  charset: nil             # or :default
}
```

`cache:` selects the delivery:

- `:complete_body` — the shared complete-body lifecycle: a
  `{:complete_body, content_type}` cache entry, `If-None-Match: *` honored on a
  hit, fail-open write on a miss.
- `:none` — the internal cache is neither read nor written, and the content
  type is negotiated against the *current* request's `Accept` over `offers`
  (the first entry whose tokens appear in `Accept` wins), with `Vary: Accept`
  stamped.

On the declarative tier you don't build the struct directly. Set
`render: {:custom, module, params}` on the Plan and implement
`ImagePipe.Renderer`:

```elixir
@callback requires(params :: map()) :: [:header]
@callback render(RenderContext.t(), params :: map(), keyword()) ::
            {:ok, {content_type :: String.t(), iodata()}} | {:error, term()}
```

The base turns that into a `%RenderTerminal{cache: :none}` whose `offers` come
from `params[:offers]`, and runs the renderer through `ImagePipe.Renderer.run/3`,
which owns the `[:render]` span. `requires/1` declares which expensive
pipeline stages the renderer needs (currently `:header` — decoded header
facts). `render/3` receives an `ImagePipe.Plan.RenderContext` whose `info` is an
`ImagePipe.Plan.SourceInfo` (format, stored dimensions, EXIF orientation, byte
size) and returns the complete response body.

Plan validation enforces the pairing: `render: :image` requires an `%Output{}`;
a custom render requires `output: nil`. Every failure inside the render
terminal — fetch, decode, input limit, and the one the renderer itself
returns — carries a
`{:render, inner}` envelope, so `render_error/3` can distinguish a
render-terminal failure from an image-terminal one.
`ImagePipe.Dialect.IIIF.InfoRenderer` is the complete example.

## The contract surface

These are the public, stable pieces a dialect is written against:

| Module | What it is |
|---|---|
| `ImagePipe.Dialect` | the six-callback behaviour, plus `safe_transform/1` and `parse_boolean/1` |
| `ImagePipe.Dialect.Declarative` | the declarative tier's `use` base: `parse_plan/2`, `config_keys/0`, `validate_config!/1` |
| `ImagePipe.Dialect.Resolved` | the product of `prepare/3` — values, not callbacks |
| `ImagePipe.Dialect.Negotiation` | the negotiation outcome; `negotiate/3` for an image terminal, `terminal/1` for a render one |
| `ImagePipe.Dialect.RenderTerminal` | a non-image terminal |
| `ImagePipe.Dialect.Failure` | a lifecycle failure tagged with the phase that produced it |
| `ImagePipe.Dialect.SharedConfig` | the shared runtime option keys and their validation |
| `ImagePipe.Plan` and `ImagePipe.Plan.*` | the product-neutral request model |
| `ImagePipe.Renderer` | the non-image renderer behaviour and its dispatch entry point |
| `ImagePipe.Transform` | the transform entry point a dialect pipeline drives |

Everything behind the runner is **private, with no stability promise**. In particular, a
dialect must not depend on in-tree implementation helpers such as
`ImagePipe.Transform.Lowering` or `ImagePipe.Transform.ResizePlanning` — those
are internal seams for the in-tree dialect pipelines and may change without
notice.

`ImagePipe.Response.ErrorStatus` sits in between: every in-tree dialect's error
module routes through it, and this guide recommends you do too, but it carries
`@moduledoc false` and isn't part of the published API. Treat its table as
shared convenience, not a stability promise.

## Testing a dialect

Follow the two-tier layout the in-tree dialects use:

- **Unit tests** in `test/image_pipe/dialect/<name>/` — grammar,
  path/endpoint classification, plan or request building, config validation.
  Assert on what your `parse_plan/2` (or `parse/2`) produces. StreamData
  property tests earn their keep for order-insensitivity, unit conversion, and
  canonicalization invariants.
- **Wire-level tests** — a compact, representative set of real requests driven
  through `ImagePipe.Plug`, asserting user-visible contracts: status
  codes, content types, decoded output dimensions, `Vary`/negotiation, error
  statuses from `render_error/3`, and that request-safety failures (bad
  grammar, bad signature) return **before** any source or cache access. See
  `test/image_pipe/dialect/iiif/wire_test.exs` for shape and scale — keep
  combinatorial grammar coverage in the unit tier.

Assert ETags as **round-trips** (issue a second request with
`if-none-match: <etag>` and expect `304`) rather than pinning literal strings:
the value comes from `ImagePipe.Representation`, and pinning it tests the
mechanism instead of the contract. Keep the assertions about *separation* (two
different requests must not share an ETag) and *stability* (the same request
twice yields the same ETag) — those are the real contract. Remember that a
declarative dialect emits no ETag at all without `http_cache: [mode: :enabled]`.

## Conventions checklist

Beyond the code itself, a new in-tree dialect should:

- **Declare its boundary.** `use Boundary, top_level?: true` on the top-level
  dialect module. A concrete dialect may depend on `ImagePipe.Dialect` (plus
  `ImagePipe.Dialect.Declarative` and `ImagePipe.Dialect.SharedConfig`) and
  core toolkit facades only — never another dialect, never `ImagePipe.Plug`,
  and never `ImagePipe.Cache` or `ImagePipe.Delivery`, which the runner owns.
  Export nothing unless the host must implement a callback the dialect calls
  (e.g. an id resolver).
- **Ship a conformance doc.** Each compatibility target gets
  `docs/<target>_support_matrix.md` documenting the supported surface,
  processing-stage mapping, and deliberate divergences — and that doc must be
  updated in the same change as any parity-affecting behavior change.
- **Register docs.** Add the support matrix (and any companion docs) to the
  ExDoc `extras` in `mix.exs`. Modules under `ImagePipe.Dialect.*` are grouped
  under "Dialect API" automatically.
- **Keep the demo in sync.** The fiddle app (`fiddle/assets/`) should be able
  to exercise the dialect's options end-to-end when it is meant to be demoable.

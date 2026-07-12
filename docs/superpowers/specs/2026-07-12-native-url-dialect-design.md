# Native URL dialect — design

**Status:** approved design, pre-implementation
**Date:** 2026-07-12

## Overview

ImagePipe currently ships three compatibility parsers (imgproxy, TwicPics,
IIIF) and no dialect of its own. This design defines **ImagePipe's native URL
dialect**: a clean-sheet path grammar informed by imgproxy's lessons, mapping
onto the existing `ImagePipe.Plan` machinery with no new transform semantics.

The dialect keeps imgproxy's good bones — path-based signable URLs,
declarative options with a fixed processing pipeline, source-last shape,
cache-transparent presets — and sheds the accreted grammar: aliases,
positional colon-trains, zero-sentinels, magnitude-punned relative units,
three output-format mechanisms, and the guess-where-the-source-starts split
rule.

### Goals

- One canonical spelling for every concept. No aliases, ever.
- Self-documenting URLs: readable in logs, hand-writable, srcset-friendly.
- A grammar small enough to spec in a page and reproduce byte-exactly in any
  client language (URL builders, signers).
- Full parity with today's `ImagePipe.Plan` surface, including operations the
  imgproxy parser doesn't expose (`gray`, `bitonal`, `trim`, explicit-region
  crop).
- Verify-before-parse signing; all validation failures return before source
  identity resolution, cache access, or source fetch.

### Non-goals (v1)

- Encrypted sources (`enc/` is a reserved marker for later).
- Key-id signatures (`sig=<id>.<mac>` is a reserved backward-compatible
  extension; see Signing).
- TwicPics-style parenthesized arithmetic in values.
- Watermarks (not in `Plan` today).
- Multi-group presets combined with URL `then` groups.
- Object-weight crop guides (`CropGuided` weights): reachable in `Plan`, no
  native spelling yet; `anchor=smart` covers today's imgproxy-parser parity.
- URL-level security-limit overrides (imgproxy `max_src_resolution` etc.) —
  host config only.

## URL anatomy

Everything is path; the query string is ignored by the parser and left to the
host application.

    /[sig=<mac>/]<option|then>.../src/<source>
    /[sig=<mac>/]<option|then>.../src64/<base64url-source>

Paths are interpreted relative to the Plug mount point.

### Segment types

A path is a sequence of `/`-separated segments, each exactly one of:

1. **Signature** — `sig=<base64url-hmac>`. Only valid as the first segment.
   Verified before anything is parsed. See Signing.
2. **Option** — `key=value`. Keys are lowercase `[a-z0-9-]`, exactly one
   canonical spelling per concept. Values may be comma-lists with fixed arity
   per key.
3. **Flag** — a bare boolean key (`extend`). Only defined flags parse; an
   unknown bare segment is a 400, never a source guess.
4. **Group separator** — the reserved word `then`. Starts a new pipeline
   group.
5. **Source marker** — `src` or `src64`. Terminal: everything after it,
   slashes included, is the source value.

Reserved words: `src`, `src64`, `then`, `sig`, `enc` (future), plus `auto` as
a value keyword.

### Sources

- `src/` takes the source string verbatim (slashes intact). Only `%`, `?`,
  and `#` must be percent-encoded — the same minimal set imgproxy's plain
  form requires. The source string is the percent-decoded remainder of the
  path.
- `src64/` takes the URL-safe Base64 encoding of the source string. `/`
  characters inside the value are ignored (the value may be split across
  segments); trailing `=` padding is optional.
- Both forms feed the same source translation used by the other parsers
  (relative path → configured source; scheme forms per host config).
- `src64` is routing syntax, not secrecy: the source is recoverable from the
  path, and the path appears wherever the host logs paths.

There is no output-extension suffix on the source (`@ext` / `.ext` do not
exist). `format` is the only format mechanism.

## Value micro-syntax

One spelling per concept, applied uniformly:

- **Numbers** — plain decimal (`2.5`, `90`, `-10`). No `0`-as-sentinel
  anywhere: "auto" is spelled `auto`, and absence means default.
- **Lengths** — bare number = pixels; `pct` suffix = percentage of the
  relevant dimension (`crop=80pct,60pct`). No magnitude punning. (`pct`, not
  `p`: `80p` misreads as pixels, and bare numbers already are pixels.)
- **Coordinates** — `focus` takes unitless 0–1 fractions: it is a position in
  unit space, not a length.
- **Booleans** — flags are spelled bare for true (`extend`), `key=false` to
  negate (meaningful when overriding a preset). `key=true` is a 400: the bare
  form is the one spelling of true.
- **Pairs/lists** — comma-separated, fixed arity per key.
- **Colors** — bare 3/6-digit hex (`fff`, `f4f4f4`) or CSS basic color names.
  No `#` (it would start the URL fragment).
- **Ratios** — `16:9` or a decimal (`:` is legal in path segments).

## Option vocabulary

Keys and enum values use lowercase `[a-z0-9-]`. High-frequency keys get short
canonical names (`w`, `h`, `q`, `bg`, `pad`, `cb`); everything else is a full
word. One spelling each.

### Geometry (group-scoped)

| Key | Value | Maps to |
| --- | --- | --- |
| `w`, `h` | px or `auto` | Resize target |
| `fit` | `contain` \| `cover` \| `cover-down` \| `stretch` \| `auto` | Resize mode |
| `min-w`, `min-h` | px | Minimum dimensions |
| `zoom` | factor, or `x,y` factors | Zoom |
| `dpr` | factor | DPR; affects offsets/padding like imgproxy |
| `enlarge` | flag | Allow upscale |
| `extend` | flag | Extend canvas to the target box |
| `extend-at` | anchor | Extend gravity (default `center`) |
| `extend-offset` | `x,y` lengths (px/pct) | Offset from the extend anchor |
| `extend-ratio` | flag | Extend canvas to the w/h aspect ratio |

`fit` naming: imgproxy `fill` ≡ CSS `cover`, while CSS `fill` ≡ imgproxy
`force` — the word `fill` is a trap in both directions and is not used.
`contain`/`cover` take their CSS senses; `stretch` replaces `force`;
`cover-down` replaces `fill-down`.

### Crop & placement (group-scoped)

The two Plan crop shapes get distinct keys instead of one overloaded `crop`:

| Key | Value | Maps to |
| --- | --- | --- |
| `crop` | `w,h` (px/pct) | Guided crop (`CropGuided`), guided by `anchor`/`focus` |
| `region` | `x,y,w,h` (px/pct) | Explicit-region crop (`CropRegion`) |
| `anchor` | `center`, `top`, `top-left`, … `bottom-right`, `smart` | Crop guide and result-crop gravity for `cover` |
| `anchor-offset` | `x,y` lengths (px/pct) | Offset from the anchor (replaces imgproxy's `>=1`-px/`<1`-relative punning) |
| `focus` | `x,y` fractions 0–1 | Focal point; mutually exclusive with `anchor` |
| `crop-ratio` | `16:9` or decimal | Crop aspect-ratio correction |
| `crop-ratio-enlarge` | flag | Grow-not-shrink correction |
| `trim` | `auto`, or color[,tolerance] | Trim surrounding background |

### Orientation

| Key | Value | Scope |
| --- | --- | --- |
| `orient` | `auto` (default) \| `none` — EXIF policy | request |
| `rotate` | `90` \| `180` \| `270` | group |
| `flip` | `h` \| `v` \| `hv` | group |

### Effects (group-scoped, fixed order within a group)

| Key | Value |
| --- | --- |
| `blur`, `sharpen` | sigma |
| `pixelate` | block px |
| `brightness`, `contrast`, `saturation` | −100..100 |
| `gray`, `bitonal` | flags |
| `monochrome` | `intensity[,color]` |
| `duotone` | `intensity[,dark,light]` |
| `colorize` | `opacity,color[,keep-alpha]` |
| `gradient` | `opacity,color[,direction,start,stop]` |

Accepted micro-wart: `colorize`/`gradient` keep short fixed-arity positional
tails; per-argument keys would be heavier than the problem.

### Composition (group-scoped)

| Key | Value |
| --- | --- |
| `pad` | CSS 1–4 value shorthand, px |
| `bg` | `color[,alpha]` — folds imgproxy's separate `background_alpha` |

### Output & delivery (request-scoped)

| Key | Value |
| --- | --- |
| `format` | `avif` \| `webp` \| `jpeg` \| `png` \| `jxl`; absent ⇒ `Accept` negotiation + `Vary: Accept` |
| `q` | 1–100 |
| `format-q` | `avif:60,webp:70` colon-pairs |
| `meta` | `strip` (default) \| `keep` |
| `keep-copyright` | flag |
| `profile` | `strip` (default) \| `preserve` |
| `hdr` | `tonemap` (default) \| `preserve` |
| `autoquality` | same arguments as the imgproxy option, comma-list with optional tail |
| `max-bytes` | byte budget |
| `jpeg-options`, `png-options`, `webp-options`, `avif-options` | encoder options as a comma-list of flags and `name:value` pairs (e.g. `jpeg-options=progressive,quant-table:3`) |
| `debug` | flag — debug response headers, mirroring the imgproxy parser's `debug` |
| `preset` | one or more configured preset names |
| `cb` | cachebuster string |
| `expires` | unix timestamp; past ⇒ 404 |
| `filename` | disposition stem |
| `attachment` | flag |

### Dropped from imgproxy with no replacement

Aliases; meta-options (`resize`, `size`, `adjust`); `@ext`/`.ext` suffixes;
zero-sentinels; `1/t/true` boolean spellings; magnitude-punned relative
units; security-limit overrides; `raw`; `skip_processing`; base64-encoded
text values.

## Request semantics

### Pipeline groups

`then` splits the URL into ordered groups. Each group is one pass of the same
fixed canonical operation order used today: orientation → region/guided crop
→ resize → result crop → effects (fixed internal order) → canvas extend →
padding → background. A single-group URL is the common case.

Ordered groups are a deliberate keep (not just compatibility): they are a
cost-control lever — `/w=500/then/trim=fff` trims a 500px image instead of a
full-resolution one, and trim/smart-crop are the materialization-heavy
operations.

Empty groups (leading, trailing, or doubled `then`) are a 400, not silently
skipped.

### Scoping and duplicates

- Transform keys are group-scoped. The same key twice within a group is a
  400 — no last-wins, which only masks client bugs.
- Request-scoped keys (`format`, `q`, `format-q`, `meta`, `keep-copyright`,
  `profile`, `hdr`, `autoquality`, `max-bytes`, the four `*-options` encoder
  keys, `debug`, `orient`, `cb`, `expires`, `filename`, `attachment`,
  `preset`) may appear in any group but at most once per URL; a second
  occurrence anywhere is a 400.
- Mutual exclusions are errors, not precedence rules: `focus`+`anchor`,
  `crop`+`region`, and `extend`+`extend-ratio` in one group are 400s
  (extending to the full box already fixes the ratio — stating both is
  contradictory intent), as is `autoquality`+`q` anywhere in the URL (an
  explicit quality and a quality search are contradictory instructions).
  `q`+`format-q` is allowed with stated precedence — `format-q` wins for its
  format — because combining them with negotiation is useful, not
  contradictory. `max-bytes` composes with either.

### Inertness policy

imgproxy's other silent-failure family is the inert option: `exar` with an
auto dimension, `crop_ar` without a crop, gravity with nothing to crop — all
silently no-op, masking client bugs. The native policy has three tiers.
The philosophical line: **identity is meaningful input; inertness is a bug.**

**Tier 1 — identity values of continuous parameters are valid and emit no
operation.** `dpr=1`, `zoom=1`, `blur=0`, `brightness=0`, `pixelate=1`,
`monochrome=0` are the identity points of their parameter spaces, not
sentinels — templated builders legitimately emit them (`dpr=${ratio}` on a
1× device must not 400). Values outside the parameter space remain invalid
(`pixelate=0` is not identity; 400).

**Tier 2 — structurally inert options are a 400** (subject to the host
opt-out below). An option whose prerequisite is absent cannot take effect;
that is a client bug and we say so:

| Option | Requires (same group) |
| --- | --- |
| `extend-ratio` | concrete (non-`auto`) `w` **and** `h` |
| `extend-at`, `extend-offset` | `extend` or `extend-ratio` |
| `extend` | a resize box (`w` and `h`) |
| `anchor-offset` | `anchor`, and `anchor` ≠ `smart` |
| `anchor`, `focus` | a consumer: `crop`, or `fit` ∈ {`cover`, `cover-down`, `auto`} |
| `crop-ratio` | `crop` |
| `crop-ratio-enlarge` | `crop-ratio` |
| `enlarge` | a resize intent (`w`, `h`, `min-w`, or `min-h`) |
| `keep-copyright` | metadata stripping active (400 with `meta=keep`) |

`fit=auto` counts as a valid `anchor`/`focus` consumer at parse time:
whether the crop happens is decided at runtime (orientation match → cover),
so there is no false rejection.

**Tier 3 — contradictions** are the exclusive pairs above: always 400, no
opt-out.

**Host opt-out (Tier 2 only).** `on_inert_option: :reject` (default) or
`:ignore` in the parser config. Ignore mode drops the inert option, serves
what the rest of the URL says, and emits a telemetry warning event
(`[:image_pipe, :parser, :inert_option]`, carrying the dropped key and its
missing prerequisite) that the default Logger and OTel capture surface. The
knob is host config, never per-URL — a URL-level flag would let the buggy
author silence their own alarm. Unknown keys, invalid values, duplicates,
and contradictions have no safe fallback interpretation and stay
unconditional 400s in both modes. Cache keys are unaffected: an ignored
inert option never reaches the Plan, so strict and lenient hosts produce
identical canonical plans.

### Presets

Host-configured, written in the native dialect itself. `preset=card` expands
in place before planning — cache-key-transparent, same as today: preset names
never reach the Plan, runtime state, or cache key. Expansion rule: explicit
URL keys override preset-provided keys in the same group (explicit-beats-
preset, not positional last-wins). A preset may contain `then` groups and
expands as its full group sequence, but combining a multi-group preset with
URL `then` groups is a 400 in v1. A configured `default` preset applies to
every request, overridable per key.

### Output negotiation

Unchanged from today's model: no `format` ⇒ negotiate from `Accept` and set
`Vary: Accept`; explicit `format` bypasses negotiation and does not set
`Vary`.

### Canonical form and cache keys

Within a group, options are order-insensitive: any permutation of a group's
segments produces the identical `ImagePipe.Plan`. URL spelling never enters
the cache key; Plan canonicalization owns key data, same as today.

### Failure behavior

All of the following are 400 with a specific reason, returned before source
identity resolution, cache access, or source fetch:

- unknown key or unknown bare flag
- invalid value for a known key (including `key=true` for flags)
- duplicate key in scope (group-scoped: per group; request-scoped: per URL)
- mutually exclusive pair (see Inertness policy, Tier 3)
- structurally inert option (Tier 2), unless `on_inert_option: :ignore`
- empty pipeline group
- unknown preset; multi-group preset combined with URL groups
- `sig=` present on an instance with no configured keys

Signature failures are 403 and occur before parsing. Past `expires` is 404.

## Signing

- Signed URLs start with `sig=<base64url-hmac-sha256>`. The MAC covers the
  path bytes **after** the signature segment, exactly as sent — from the `/`
  following the segment through the end of the path, query excluded, mount-
  relative. No canonicalization before verification: verify first, parse
  second, with zero scanning (fixed first position).
- **Keys are an ordered list** in host config. The first key signs (URL
  helpers use it); verification tries each key in order with constant-time
  comparison. Telemetry records the matched key index, so retirement is
  observable: drop the old key when its match count flatlines. Trying 2–3
  HMACs during a rotation window is sub-microsecond noise.
- No salt: HMAC-SHA256 needs none; one secret per entry keeps client signer
  implementations trivial.
- Keys configured ⇒ signature required: missing or invalid `sig` is a 403.
  No keys ⇒ unsigned allowed (dev); a `sig=` segment on a keyless instance is
  a 400, not silently ignored — an unverified signature is a false promise
  the URL author should hear about.
- Future extension: URL-safe Base64's alphabet excludes `.`, so
  `sig=<key-id>.<mac>` can be added later as a strictly backward-compatible
  form if direct key lookup ever earns its keep.

## Architecture

- **Module:** `ImagePipe.Parser.Native`, implementing the `ImagePipe.Parser`
  behaviour, translating URLs into `ImagePipe.Plan` + `Plan.Output`. It owns
  nothing downstream and uses the neutral resolver (no carried strategy — no
  dialect-specific resolve-time semantics exist in this design).
- **Config:** its own key in `ImagePipe.Plug.init/1`
  (`native: [keys: [...], presets: %{...}, on_inert_option: :reject]`),
  validated at init.
- **Reuse boundary:** the native parser must not reach into
  `Parser.Imgproxy` internals. Where plan-construction logic genuinely
  coincides, the shared piece is promoted to a neutral home first, per the
  boundary guidelines.
- **Docs:** a new `docs/native_url_api.md` is the dialect reference — the
  analogue of `imgproxy_path_api.md`. There is no conformance matrix; this
  dialect has no vendor to diverge from, so the reference doc is the ground
  truth.

## Testing

Following the house test guidelines:

- **Parser unit tests:** grammar (segment forms, reserved words, units,
  duplicate/exclusive rejections), option-by-option value validation, preset
  expansion.
- **StreamData properties:** order-insensitivity within a group (any
  permutation → identical Plan), canonicalization stability, `src`/`src64`
  round-trips, signing round-trip (sign → verify) over arbitrary option
  sequences.
- **Wire-level Plug tests,** compact and representative: signature
  required/invalid/unsigned-config matrix (403 before parse), 400-before-
  source-fetch safety, `Accept` negotiation + `Vary`, explicit `format`
  bypass, a pixel-decoding geometry case, cache reuse for semantically
  equivalent requests, `then`-group behavior (the cheap-trim case:
  resize-then-trim trims the small image).
- **Cross-dialect equivalence tier:** a handful of native URLs asserted
  byte-identical to their imgproxy-URL equivalents through the full stack —
  "same Plan in, same bytes out" — without a parallel differential suite.

## Examples

    # srcset workhorse
    /w=800/src/images/cat.jpg

    # fill a 300x400 box from a focal point, force webp
    /fit=cover/w=300/h=400/focus=0.25,0.75/format=webp/src/images/cat.jpg

    # explicit smart crop, then resize down
    /crop=600,400/anchor=smart/w=300/src/images/cat.jpg

    # resize, extend canvas, pad, flatten
    /w=300/h=400/extend/pad=20/bg=f4f4f4/src/images/cat.jpg

    # cheap trim: resize first, trim the small image
    /w=500/then/trim=fff/src/images/cat.jpg

    # relative crop with explicit units
    /crop=80pct,60pct/src/images/cat.jpg

    # signed remote source with an encoded query string
    /sig=AfrOrF3gWeDA6VOlDG4TzxMv39O7MXnF4CXpKUwGqRM/w=800/src/https://example.com/cat.jpg%3Fv%3D2

    # same source, base64
    /w=800/src64/aHR0cHM6Ly9leGFtcGxlLmNvbS9jYXQuanBnP3Y9Mg

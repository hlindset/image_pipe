# SVG output with oxvg optimization

Beads `image_plug-jom`. Draft for agreement; nothing here is implemented.

## Summary

ImagePipe rejects SVG sources today. This note proposes one new capability:
serving an SVG source as SVG, optimized by oxvg and sanitized, when the
request explicitly asks for `format=svg`.

Proposal:

- SVG output only with an explicit `format=svg`. `Accept` never selects it.
- The request picks an optimization profile by name. The host defines what
  each profile does.
- The SVG path runs no libvips and no transform groups: bounded fetch, then
  optimize and sanitize in one NIF call, then delivery with a strict CSP.
- SVG sources without `format=svg` keep returning `415`. Rasterization is out
  of scope, consistent with the loader allowlist dropping librsvg.

## Current behavior

`ImagePipe.Format.Detector` names `:svg` with a structural scan of the peek
for an `<svg>` root element. `ImagePipe.Decode` rejects `:svg` before
libvips, as `{:decode, {:unsupported_source_format, :svg}}` → `415`. The
detector can't see through gzip (svgz) or a prolog longer than the peek; both
reach libvips as `:unknown` today and get rejected once the loader allowlist
(`loader-allowlist.md`) lands.

`Accept` negotiation only chooses between AVIF and WebP
(`ImagePipe.Output.Negotiation`, `Format.modern_formats/0`).

## imgproxy for reference

From the open-source code (4.0.17) and the Pro docs and changelog:

- SVG output is possible only when the source is SVG. SVG to SVG passes the
  source through; every processing option is silently ignored.
- With no format requested, an SVG source also passes through, unless
  `IMGPROXY_ALWAYS_RASTERIZE_SVG` is set. Rasterization uses librsvg at 96
  DPI, with scale-on-load.
- Passthrough sanitizes (on by default): it removes `<script>`, `<iframe>`,
  `<form>`, about 110 `on*` attributes, and `href` values outside a per-element
  scheme allowlist. It's a blocklist. Every response also gets
  `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline';
  img-src data:; sandbox`.
- Size cap: 10 MB, disabled by `IMGPROXY_SVG_UNLIMITED`.
- Pro minifies passthrough SVGs with an in-house minifier, with no documented
  knob. Pro's `style` option prepends a `<style>` element to the root.

We depart from imgproxy in two places: no silent passthrough when no format
is requested, and no silently ignored options.

## Request surface

`format=svg` joins the output formats, with `svg-options` in the same style as
`jpeg-options`:

```
format=svg/svg-options=profile:safe
```

- `profile:<name>` selects a named profile. Built-in names: `none`, `safe`,
  `default`. Hosts may add names. Unknown names fail at parse time.
- Omitting `profile` uses the host's default profile (built-in default:
  `safe`).
- `svg-options` without `format=svg` is a parse error: unlike the raster
  per-format options, no negotiation can ever make it active. `svg` is never
  a negotiation candidate.

`format=svg` rejects, at validation and before any fetch:

- every group option (resize, crop, rotate, effects, and so on) and `orient`;
- quality, search, budget, and other encoder options;
- metadata, profile, and HDR controls;
- `output=blurhash`, `output=lqip-css`, and `output=info`.

Presets expand first, so inherited options reject too, as for `output=info`.
Delivery controls (`filename`, `attachment`) still apply, with `.svg` as the
extension.

A future request-side styling option (the SVG styling candidate in
`image_plug-que`) would belong under `svg-options`.

## Profiles

Host configuration, validated with NimbleOptions at mount initialization:

```elixir
svg: [
  default_profile: :safe,
  max_bytes: 10_000_000,
  profiles: [
    icons: [preset: :default, jobs: %{prefix_ids: %{prefix: "i"}}, disable: [:remove_title]]
  ]
]
```

- A profile is an oxvg preset (`:none`, `:safe`, `:default`) plus job
  overrides and disabled jobs, passed straight to `Oxvg.optimize/2`.
- The built-in names map to the three oxvg presets. Hosts may redefine them.
- Raw oxvg jobs never appear in URLs. Reasons: parse-time validation would need
  oxvg's job schema inside `image_pipe_url`, whose dependencies stay limited to
  `nimble_options`, `color`, and `mime`; oxvg is at 0.0.7, so job names in URLs
  would become public API tied to an unstable crate; and free-form jobs
  fragment the cache and allow arbitrarily expensive work.
- Job config is validated when the mount initializes. The binding only
  rejects bad jobs at call time, so initialization makes one test call per
  profile on a tiny SVG and raises on error.
- `image_pipe_server` needs the same profiles expressible in its
  non-Elixir configuration.
- oxvg's `safe` preset is not safe for sprite sheets. `remove_hidden_elems`
  deletes every unreferenced `<symbol>` (a real 9.7 KB icon sprite became an
  empty `<svg/>` under both `safe` and `default`), and `cleanup_ids` renames
  IDs, which breaks external `file.svg#id` references. The built-in profiles
  should disable both, or ImagePipe should ship a `sprite` profile and say so
  in the docs.

## Pipeline

1. Parse and validate (above). Nothing is fetched on failure.
2. Source resolve and fetch, with `svg.max_bytes` as the body limit
   (the lower of it and `max_body_bytes`).
3. Representation, conditional gate, and cache, as for any output.
4. Detect: the source must be `:svg`, otherwise `415` with
   `{:unsupported_source_format, family}`. svgz is rejected; decompressing it
   invites gzip bombs for little gain. A long prolog is fine here, since the
   NIF parses the whole document and fails if the root isn't `<svg>`.
5. Optimize, then sanitize, in one NIF call and one parse. Sanitizing runs
   last in every profile, including `none`, so no profile can turn it off or
   reintroduce what it removed.
6. Deliver `image/svg+xml`.

Nothing on this path touches libvips, `ImagePipe.Transform`, or
`ImagePipe.Decode`. It lives under `ImagePipe.Output.SVG` (encoding owns
it); the runner dispatches to it the way it dispatches terminals.

## Sanitizer

An allowlist, not imgproxy's blocklist: keep well-known SVG elements and
attributes, drop everything else. It is a Rust `oxvg_ast` visitor in the oxvg
binding, run after the profile's jobs inside the same parse, on the dirty CPU
scheduler that `optimize` already uses.

The oxvg tree makes this straightforward. Element and attribute names are
typed enums with an `Unknown` fallback, namespaces are resolved (so aliased
prefixes can't hide a `<script>`), entities are already decoded, and `<style>`
contents and `style` attributes are parsed by lightningcss, whose `visit_url`
reaches every CSS URL whatever its escaping. Unparseable CSS in `<style>` is
dropped by the parser.

Rules:

- Drop elements that are unknown or outside the SVG namespace, plus
  `<script>` and `<foreignObject>`. This covers HTML `<iframe>`, `<form>`, and
  so on without a list.
- Drop unknown attributes (including `data-*`), except `xmlns` and `xmlns:*`
  declarations, which prefixed names depend on. Drop the event attribute group
  and any name starting with `on`.
- `href`/`xlink:href`, compared after removing ASCII whitespace and control
  characters and lowercasing (browsers ignore tabs inside `java\tscript:`):
  fragments only on `<use>`; fragments, relative, `http(s)`, and raster
  `data:image/*` on `<image>` and `<feImage>`; fragments, relative, and
  `http(s)` elsewhere. `data:image/svg+xml` is never allowed, since it nests an
  unsanitized document.
- Drop `<animate>`, `<set>`, `<animateTransform>`, and `<animateMotion>` whose
  `attributeName` targets `href` or an `on*` attribute.
- CSS: drop `@import`; rewrite any `url()` that isn't a fragment or raster
  data URI to `url()`, in `<style>` and `style`. Drop `style` attributes oxvg
  couldn't parse. Drop presentation attributes (`fill`, `filter`, …) whose
  `url()` points elsewhere.
- The binding's `allow_dtd` stays on (editors emit entity declarations).
  Entities expand before sanitizing, and no DOCTYPE reaches the output.

A prototype of these rules (about 200 lines of Rust against the binding's
pinned oxvg 0.0.7) handled 16 XSS vectors, including aliased script, tab- and
case-obfuscated `javascript:`, entity-injected hrefs, animated `href`,
external and `data:image/svg+xml` `<use>`, and escaped CSS `url()`. On 8
real-world SVGs (7 KB to 790 KB) it changed no output, and it added at most
about 1 ms to the `default` preset.

oxvg's `remove_scripts` job is no substitute, even set to `true`: it keeps
tab- or space-obfuscated `javascript:` hrefs, `<foreignObject>`, HTML
elements, animated `href`, external `<use>`, and CSS URLs. Also note that
`jobs: %{remove_scripts: :default}` in the binding leaves the job off, because
that job's default configuration is `false`.

The sanitizer checks the tree, so it is only as good as the serializer.
oxvg 0.0.7 and 0.0.8 write parsed `<style>` content without escaping it, so a
CSS string holding `&lt;/style&gt;&lt;script&gt;…` comes out as a real
`<script>` element after sanitizing (reproduced on both versions). Upstream
fixed this on `main` (oxvg #288) after 0.0.8, so the binding needs a release
containing that fix. As defense in depth, the NIF re-parses its own output and
fails the request if the check finds anything the sanitizer would remove. That
costs one extra parse.

The CSP header is the backstop, set on every SVG response (including cache
hits and `304`s): imgproxy's policy value plus `X-Content-Type-Options:
nosniff`.

## Cache and identity

- The key and ETag include `format=svg` and the resolved profile's full
  contents (preset, jobs, disabled jobs), not its name. Editing a profile in
  host config therefore changes the key. `ImagePipe.Representation` owns the
  exact fields.
- The oxvg binding version enters the key too, since a new oxvg release can
  change output bytes for the same profile.
- No `Vary: Accept`: negotiation never applies.

## Errors and telemetry

- New error: `{:svg, reason}`, where the NIF returns a parse, optimize, or
  serialize error. A source that fails to parse is a bad source (`415`); an
  optimize or serialize error after a good parse is a `500`.
- A new `[:output, :svg]` span wraps the NIF call, with `profile`, input
  bytes, and output bytes as metadata (all non-sensitive). Add it to the
  Logger lists and to `Capture`'s `@span_stages` and `@safe_keys`, per
  AGENTS.md.

## Limits and scheduling

- `optimize` already runs on a `DirtyCpu` scheduler, but it can't be
  cancelled: a client disconnect doesn't stop it. `svg.max_bytes` is the
  control. Measure optimize time against input size to set the default;
  imgproxy's 10 MB may be too generous.
- Entity expansion: roxmltree caps nesting at depth 10 and 255 references per
  top-level reference, but not the total, so a small input can still expand
  to much more text. Measure worst-case expansion against `svg.max_bytes`, and
  consider a `nodes_limit`, before shipping.

## Tests

- Parse: `format=svg` with each rejected option class returns `400` with no
  fetch; `svg-options` without `format=svg` fails; unknown profiles fail.
- Wire: an SVG source with `format=svg` returns `200` with `image/svg+xml`,
  the CSP and `nosniff` headers, no `Vary: Accept`, and a body smaller than
  the input for `default`.
- Wire: a raster source with `format=svg` returns `415`; an SVG source
  without `format=svg` still returns `415`; svgz returns `415`.
- Sanitizer: a corpus of XSS vectors (script, event handlers, `javascript:`
  in `href`/`xlink:href` with entity tricks, `<foreignObject>`, animated
  `href`, CSS `url()`, nested `data:image/svg+xml`), asserted under every
  profile including `none`.
- Profiles: a symbol sprite sheet keeps its symbols and IDs under every
  built-in profile.
- Cache: different profiles produce different keys; editing a profile changes
  the key; `304` works before any fetch.
- Fiddle: a format choice for SVG and a profile selector.

## Open decisions

1. Option shape: `format=svg/svg-options=profile:<name>` (recommended), or a
   terminal such as `output=svg`.
2. Built-in default profile: `safe` (recommended) or `default`. oxvg's
   `default` preset can change rendering through precision rounding and ID
   removal.
3. Sanitizer home: inside the oxvg binding. The prototype shows it's
   feasible and nearly free there; a separate NIF would parse twice.
4. Default `svg.max_bytes`, pending the timing measurement.
5. Rasterization stays out of scope while the server image drops librsvg
   (`loader-allowlist.md`, decision 6). Revisit only with a concrete need for
   raster thumbnails of SVG sources.

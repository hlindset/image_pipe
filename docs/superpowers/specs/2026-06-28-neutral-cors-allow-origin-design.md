# Dialect-neutral CORS via a host `allow_origin` mount option

**Issue:** #284 — *Surface IIIF CORS through a Parser behaviour hook (remove manual mount-ahead composition)*
**Date:** 2026-06-28
**Status:** Approved design, pre-implementation

## Problem

Mounting the IIIF Image API today requires the host to manually compose
`ImagePipe.Parser.IIIF.CORS` **ahead of** `ImagePipe.Plug`. This is a
moduledoc-only contract ("mount this AHEAD") that is easy to forget — forgetting
it silently drops the `Access-Control-Allow-Origin` header on every response and
routes `OPTIONS` into `ImagePipe.Plug`, which has no CORS handling. The footgun
was caught during the #254 Phase 3 demo review.

CORS exists as a sibling plug because the `ImagePipe.Parser` behaviour is
conn-free on the success path (`parse/2` returns a tuple, never a `conn`), so a
parser has no seam to set a response header or short-circuit a preflight.

## Premise correction

Issue #284 is built on "`Access-Control-Allow-Origin: *` is IIIF-mandated." Both
halves are wrong, and that changes the right design:

1. **The IIIF spec does not mandate CORS, nor the value `*`.** Per the local
   IIIF Image API 3.0 spec (§7.1, and method support §7), CORS is a **SHOULD**,
   OPTIONS is a **SHOULD**, and the spec names only the `Access-Control-Allow-Origin`
   header — never the wildcard value. The `cors` feature is an optional
   `extraFeatures` capability. So `*` was a reasonable default *policy we chose*,
   not a conformance requirement.

2. **CORS is a host-configurable, cross-dialect concern.** imgproxy proves it:
   `IMGPROXY_ALLOW_ORIGIN` (`server/config.go`, default `""` = off) emits
   `Access-Control-Allow-Origin: <configured-origin>` + `Access-Control-Allow-Methods`
   only when set (`server/middlewares.go` `WithCORS`). CORS allow-origin is a
   generic HTTP concern with a per-deployment value, not a dialect constant.

### Sizing the option space (why not a general layering framework)

An audit of imgproxy's 178 env vars shows the behavior-relevant mount options
ImagePipe would mirror already exist as flat keys in `ImagePipe.Request.Options`
(`max_body_bytes`←`MAX_SRC_FILE_SIZE`, `max_input_pixels`←`MAX_SRC_RESOLUTION`,
`max_result_*`←`MAX_RESULT_DIMENSION`, `auto_*`←`AUTO_*`, `allow_debug_headers`←
`ENABLE_DEBUG_HEADERS`, source runtime opts←`DOWNLOAD_TIMEOUT`/`MAX_REDIRECTS`,
`http_cache`←`ETAG_*`). Every one carries a **single universal default** — tuned
per *deployment*, not per *dialect* — which is exactly why they are flat keys
with no dialect-overlay plumbing.

The number of mount options that want a **dialect-specific default** (the only
thing that needs a dialect-overlay layer) is effectively zero. CORS is the one
candidate, and once we make CORS fully neutral (below), even it has no dialect
default. So this change builds **no** general mount-config layering domain; it
adds one flat neutral option.

## Design

### Decision: fully neutral, host opts in

CORS is a flat, dialect-neutral mount option. No dialect supplies a default. A
host that wants CORS sets `allow_origin` on the mount — the same for IIIF,
imgproxy, or any dialect — exactly mirroring imgproxy's off-until-configured
model. The IIIF parser is **not** touched.

This still fixes #284's real footgun, which is *structural* ("compose a separate
plug AHEAD or it silently breaks"), not the absence of a default. Moving CORS
into the neutral core removes the sibling-plug requirement regardless of any
default.

The IIIF spec is only a SHOULD and the value is not mandated, so host-opt-in is
spec-honest. The ergonomic risk — IIIF browser viewers (Mirador/UV/OpenSeadragon)
fetch `info.json` cross-origin and require CORS — is mitigated by documentation:
the canonical IIIF mount snippet and the fiddle mount both set
`allow_origin: "*"`, so the copy-pasteable path is correct without baking dialect
knowledge into code.

### 1. The option

`allow_origin` is a flat top-level mount option in `ImagePipe.Request.Options`,
alongside `max_body_bytes` / `allow_debug_headers` / etc.

- Type `:string`, **default `nil`** (CORS off).
- Empty string is rejected at `Options.validate!` (use `nil` / omit for off).
- The value is emitted verbatim as the header value (`"*"` or a specific origin).
- No origin-format validation, no list / reflection, no `Vary: Origin` — a single
  static value, matching imgproxy's entire surface (YAGNI).
- `allow_origin` is a generic CORS term; naming it in the neutral core / Options
  does not name any dialect.

### 2. The mechanism (entirely in the neutral core)

A neutral helper `ImagePipe.Response.CORS` (response decoration belongs in the
`Response` boundary) with two entry points the core `ImagePipe.Plug` calls:

- **Header decoration** — at the top of `ImagePipe.Plug.call/2`, when
  `allow_origin` is set, `register_before_send/2` stamps
  `Access-Control-Allow-Origin: <value>`. Being a before-send hook, it lands
  uniformly on **every** outcome: image, `info.json`, 303 redirect,
  parser/source/plan errors, 304, the OPTIONS response, and a 405.
- **OPTIONS handling** — OPTIONS is **always answerable** (it is HTTP capability
  discovery, RFC 9110 §9.3.7), so the `do_call` method guard gains an `OPTIONS`
  branch that responds regardless of CORS:
  - always → `204 No Content` + `Allow: GET, HEAD`.
  - additionally, when `allow_origin` is set → `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`
    (and the before-send hook adds `Access-Control-Allow-Origin`).
  - The `OPTIONS` handler itself only sets `Allow` (+ `Access-Control-Allow-Methods`
    when CORS is on); `Access-Control-Allow-Origin` comes from the shared
    before-send hook so there is one source for it.
- **405** stays reserved for genuinely unsupported methods (`PUT`/`POST`/`DELETE`/…),
  where it is unambiguously correct and already carries `Allow: GET, HEAD`.

Rationale for always-answer: returning `405` to an OPTIONS *capability query* is
permitted but self-contradictory ("you may not ask what's allowed"). Treating
OPTIONS as always-answerable (2xx + `Allow`) is the conventional, §9.3.7-idiomatic
response; only the CORS headers are conditional.

`Access-Control-Allow-Methods` is `GET, HEAD, OPTIONS` — accurate to the methods
the neutral core actually allows. (The old IIIF plug and imgproxy emit the
narrower `GET, OPTIONS`; there is no conformance reason to mirror that in the
neutral core.)

#### Minor divergences from imgproxy

- Both always respond to OPTIONS; imgproxy uses `200` empty, the neutral core
  uses the idiomatic `204 No Content`. If a future imgproxy parser wants exact
  `200` parity, that is an imgproxy-adapter concern, not the neutral core.
- imgproxy's `WithCORS` middleware sets `Access-Control-Allow-Methods` on **every**
  CORS response (GET/HEAD/OPTIONS). The neutral core scopes
  `Access-Control-Allow-Methods` to the **OPTIONS** response only (the before-send
  hook adds just `Access-Control-Allow-Origin` to GET/HEAD/error/304). This is
  intentional: `Access-Control-Allow-Methods` is a *preflight*-response header, so
  emitting it only on OPTIONS is the CORS-spec-idiomatic behavior.

### 3. Cache interaction

The CORS header is applied at send time via `before_send`, **after** any cache
read — so it is never baked into cached bytes, the cache key, or the ETag. CORS
stays a pure delivery decoration, host-tunable without busting storage, per the
cache guidelines.

### 4. Telemetry

The OPTIONS response is a new request outcome (previously OPTIONS fell into
`:method_not_allowed`). Add an `:options` result tag on the `[:request]` span —
it covers OPTIONS whether or not CORS is configured, since OPTIONS is now always
answered and only the headers differ. No new event **names** — just a new result
value the generic Logger renderer already surfaces. Keep both subscription
surfaces in sync per the telemetry guidelines: the opt-in Logger
(`ImagePipe.Telemetry.Logger`) and the OTel `Capture` (`@safe_keys` / stage
lists). Cross-check that the new result value renders with its outcome and that
`docs/telemetry.md` stays aligned.

## Removals (the #284 footgun cleanup)

- **Delete `ImagePipe.Parser.IIIF.CORS`** (`lib/image_pipe/parser/iiif/cors.ex`)
  entirely — no longer a host-facing "mount this ahead" plug.
- **Fiddle `ImagePipeFiddleWeb.IIIF`** (added in #254): drop the
  `CORS.call → ImagePipe.Plug.call` wrapper; delegate straight to
  `ImagePipe.Plug` with `allow_origin: "*"` in the mount opts.
- **`test/parser/iiif_wire_test.exs`** (`call_iiif/3`, `call_options/1`): stop
  hand-composing `CORS.call` / `CORS.init`; exercise CORS through `ImagePipe.Plug`
  directly with `allow_origin: "*"`.
- **IIIF parser untouched** — no `validate_options!` change, no overlay. The
  `iiif_overlay/0` / `imgproxy_overlay/0` / `twicpics_overlay/0` seams stay as-is
  for plan/output; CORS never enters them.

## Docs

- **`docs/iiif_3_support_matrix.md`** — update the `cors` row and the wire-test
  note. CORS is now a neutral-core, host-configured feature, not an
  IIIF-mounted sibling plug. Axes touched: **surface** (the new `allow_origin`
  option) and **stage/order** (core OPTIONS handling + before-send decoration).
  Document that the IIIF mount snippet sets `allow_origin: "*"`.

## Tests

- **New neutral wire tests** (the core mechanism, proven dialect-neutral by
  exercising it through **both** the IIIF and imgproxy parsers):
  - with `allow_origin` set: image / error / 303-redirect / 304 responses carry
    `Access-Control-Allow-Origin: <value>`; `OPTIONS` → `204` + `Allow: GET, HEAD`
    + `Access-Control-Allow-Methods: GET, HEAD, OPTIONS` + `Access-Control-Allow-Origin`.
  - without `allow_origin`: `OPTIONS` → `204` + `Allow: GET, HEAD`, and **no**
    `Access-Control-*` headers on any response.
  - an unsupported method (e.g. `PUT`) → `405` + `Allow: GET, HEAD` (unchanged).
  - Telemetry assertions for the `:options` result use a unique
    `telemetry_prefix` (global-handler discipline).
- **`Options.validate!`**: accepts a valid `allow_origin`, rejects `""`.
- **Architecture/boundary test**: unchanged guarantee — the core names no
  dialect (CORS never did, post-change).

## Out of scope

- **Parser-aware default-config introspection** (`ImagePipe.Parser.default_config/2`):
  captured as #421. Deferred — no consumer, the dialect-overlay layer it would
  expose is empty today, and it needs public surface we deliberately did not add.
- **A general mount-config layering domain**: not built — the option audit shows
  mount options want flat universal defaults, not a dialect-overlay layer.
- **Multiple origins / `Origin` reflection / `Vary: Origin`**: single static
  value only, matching imgproxy.
- **Gating the IIIF `info.json` `cors` extraFeature on `allow_origin`**: the IIIF
  info renderer (`lib/image_pipe/parser/iiif/info.ex`) advertises `"cors"` in
  `@extra_features` statically. Post-change that is accurate only when the host
  sets `allow_origin` (the canonical mount does). Making the advertisement
  conditional would couple the IIIF info renderer to the neutral mount option for
  a `SHOULD`-level cosmetic feature — deferred. The conformance doc records the
  assumption instead.

## Acceptance criteria

- [ ] `allow_origin` is a validated flat option in `ImagePipe.Request.Options`
      (`:string`, default `nil`, rejects `""`).
- [ ] `ImagePipe.Response.CORS` provides neutral before-send decoration +
      always-answer OPTIONS handling; `ImagePipe.Plug` invokes it generically,
      naming no dialect.
- [ ] A bare `ImagePipe.Plug, parser: ImagePipe.Parser.IIIF, …, allow_origin: "*"`
      mount emits `Access-Control-Allow-Origin: *` on image / info.json /
      303-redirect / error / 304, and answers `OPTIONS` → 204 + `Allow: GET, HEAD`
      + `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`.
- [ ] With `allow_origin` unset, `OPTIONS` → 204 + `Allow: GET, HEAD` and **no**
      `Access-Control-*` headers; `PUT`/etc. → 405; the same mechanism works
      through a non-IIIF parser when configured.
- [ ] `ImagePipe.Parser.IIIF.CORS` deleted; fiddle `IIIF` mount and
      `iiif_wire_test.exs` no longer hand-compose CORS.
- [ ] `:options` result tag wired through the `[:request]` span, the opt-in
      Logger, and the OTel `Capture`; `docs/telemetry.md` aligned.
- [ ] `docs/iiif_3_support_matrix.md` `cors` row + wire-test note updated.
- [ ] Boundary tests confirm the core still names no dialect.

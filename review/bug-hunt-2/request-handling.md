# Bug hunt 2: request handling

Scope: URL lexing and parsing into plans, presets (static and looked up), signing and source encryption, option validation, error responses, and request-layer headers (ETag, Vary, conditional GET, CORS, OPTIONS/405), in `image_pipe` and `image_pipe_url` at `main` b50bca8.

How it was checked: both projects compiled in this cloud session. I fuzzed `Path.extract/2` + `Parser.parse/2` + `DiagnosticRenderer.render/2` with every option key against about 90 tricky values, then 60,000 random multi-option paths with valid values, `-` separators, static presets and request defaults. Findings were then replayed through `ImagePipe.Plug.call/2` with `Plug.Test` against the File source and `priv/static/images/beach.jpg`.

## Earlier fixes

All five bugs in `bug-hunt/request-handling.md` are fixed on main. `fix/request-handling-bugs` is fully merged (`git merge-base --is-ancestor` succeeds). The relevant commits:

- Preset newline crash: 21530e0 anchors the value patterns.
- Four valid signatures: e69979a accepts only the canonical spelling.
- `wm-enc` preset crash: 466dea1 falls back to a whole-path span, and dca14a9 rejects a static `wm-enc` without encryption keys at config time.
- Error `Vary` overwrite: 66f172d merges into the host's value.
- `q=0.`: `negotiation.ex:14` now uses the RFC 9110 qvalue pattern.

None of the earlier "suspicious" items changed, and I found nothing new about them.

## 1. An unknown preset plus `<option>=unset` crashes the request (500)

- Severity: medium
- Confidence: confirmed, at the parser and through `ImagePipe.Plug.call/2`
- Where: `image_pipe_url/lib/image_pipe/api/parser.ex:383-386` (the `{:error, issues}` branch of `expand_presets/5`), which crashes in `image_pipe_url/lib/image_pipe/plan/spec/validation.ex:146` (`crop_requirements/3`) and `:177` (`watermark_requirements/3`). The same pattern is at `:88` and `:157`/`:165`.
- Cause: When preset expansion fails, the parser drops only the `"preset"` key and passes the rest of the group maps to `Spec.errors/4` unchanged. Those maps can still hold the literal `:unset` value that `dispatch_value/2` (`parser.ex:207`) produces. The success path removes `:unset` inside `Presets.expand/4` (`plan/presets.ex:107`, `drop_unset/1`), but the error path never does. `Validation` assumes boolean flags: `Map.get(group, :extend, false) and ...` raises `BadBooleanError` on `:unset`, and `not Map.get(group, :watermark_tile, false)` raises `ArgumentError`.
- Repro (any mount, no signing needed when the mount is unsigned):
  - `GET /extend=unset/preset=nope/src/beach.jpg` raises `BadBooleanError` ("expected a boolean on left-side of "and", got: :unset").
  - `GET /preset=nope/wm-tile=unset/src/beach.jpg` raises `ArgumentError`.
  - `extend-ratio=unset` and `crop-ratio-enlarge=unset` behave the same.
  - The same paths with a preset that exists return 200, and without `preset=` they return 200.
  - With a `PresetLookup` whose `fetch/2` returns `{:ok, %{}}`, `GET /extend=unset/preset=n1/...` also raises. The documented result for a missing looked-up name is 400.
- Impact:
  - A documented 400 (unknown preset) turns into an unhandled exception and a 500 with a crash report, which any client can trigger cheaply on an unsigned mount.
  - The builder produces these URLs itself. `ImagePipe.URL.new() |> group(presets: ["nope"], extend: :unset) |> url("a.jpg")` returns `/preset=nope/extend=unset/src/a.jpg`, and `validate/1` returns `:ok`. That is intended for request-time lookup presets, which the server may not know. So on signed mounts a legitimate, signed URL can still crash once a looked-up preset is deleted.
- Suggested fix: in the error branch, also drop `:unset` values, e.g. `Map.new(clean_group_maps, fn {i, opts} -> {i, opts |> Map.delete("preset") |> Map.reject(&match?({_, :unset}, &1))} end)`, and the same for `clean_request_map`. Add a parser test for `extend=unset/preset=missing` and `wm-tile=unset/preset=missing` that expects `{:error, {:invalid_request, [%{reason: :unknown_preset}]}}`, plus one Plug wire test asserting 400.

## 2. A URL naming more than `max_preset_lookups` presets returns 500 "configuration error"

- Severity: low
- Confidence: confirmed through `ImagePipe.Plug.call/2`
- Where: `image_pipe/lib/image_pipe/presets.ex:86-91` (`within_limit/2`), which `fetch_levels/3` calls with the request's own names on the first level.
- Cause: The cap counts every distinct non-static name, including the first level, which comes straight from the URL. Exceeding it returns `{:preset, :invalid_definition}`, which `ErrorStatus` maps to 500 "configuration error" (`error_status.ex:204`). The limit exists to bound nested lookups in host-stored definitions, but the first level is client input.
- Repro: mount with `preset_lookup: {L, []}` whose `fetch/2` returns a fragment for every name. `GET /preset=n1,n2,...,n33/src/beach.jpg` returns `500 configuration error`.
- Impact: any client of a mount with `preset_lookup` can produce server-error responses at will. That pollutes 5xx alerting and error budgets, and blames the host's configuration for a client mistake. The status is documented in the `ImagePipe.PresetLookup` moduledoc table (`preset_lookup.ex:42`), so this is a contract choice to revisit rather than drift.
- Suggested fix: check the URL's own distinct names against the cap before the first `fetch/2`, and answer with a 400 diagnostic on the `preset=` span, e.g. reason `:too_many_presets`. Keep 500 for the nested levels that come from stored definitions. Update the doc table.

## 3. `Vary: Accept` is sent when nothing can be negotiated

- Severity: low
- Confidence: confirmed through `ImagePipe.Plug.call/2`
- Where: `image_pipe/lib/image_pipe/output/request_policy.ex:77-78` (`negotiation/3`).
- Cause: Any request without an explicit `format=` gets `[{"vary", "Accept"}]`, even when `Negotiation.modern_candidates/2` can never return a candidate, because `auto_avif: false` and `auto_webp: false` are set or libvips can't write either format.
- Repro: mount with `auto_avif: false, auto_webp: false`. `Accept: image/webp` and `Accept: image/avif,image/webp,*/*` both get the same JPEG and the same ETag, and both carry `Vary: Accept`.
- Impact: a CDN or browser cache keys the response on every distinct `Accept` string (each browser and version sends a different one), which lowers shared-cache hit rates for byte-identical output. Nothing is served wrongly.
- Suggested fix: add `Vary: Accept` only when the enabled and capable modern format list is non-empty, using the same `enabled_modern_formats/1` that negotiation uses, so `Vary`, the cache key and the ETag stay consistent. Add a wire test with both auto formats off that asserts no `Vary`.

## Checked and found correct on main

- Signature verification still runs before lexing, accepts only the canonical 43-character spelling, compares with `:crypto.hash_equals/2`, and returns 400 (not 403) for `sig=` on a mount without keys.
- `enc/` and `wm-enc` tokens are authenticated (A256CBC-HS512) before unpadding, checked for canonical base64, and redacted in diagnostic bodies. A `wm-enc` that came from a preset now gets a whole-path span instead of crashing.
- The value patterns in `value.ex` and `option_spec.ex` use `\A...\z`. Fuzzing found no crashes from huge integers, long fractions, `1.`, `-0` or exponent forms in any option. `parse_crop_ratio/1` and `parse_offset/1` guard float overflow.
- Diagnostics never carried a `nil` span across the 60,000 fuzzed paths, and the renderer never raised.
- Query strings, `.`/`..` segments, percent escapes in option segments, and `sig=` outside the first segment are rejected with 400 before any source access.
- Conditional GET: strong and `W/` matches give 304 for GET and HEAD with the allowlisted headers. `If-None-Match: *` is only honored after a cache hit. `expires` returns 410 before the conditional check.
- Error responses carry Plug's default `cache-control: max-age=0, private, must-revalidate`, so shared caches don't store them.
- `filename=`/`attachment` don't change the ETag or the cache key, but `Content-Disposition` is rendered per request on every delivery path, so a cache hit never serves another URL's disposition.
- The reserved word `unset` can't collide with a watermark name (`config.ex:401`). `preset=unset` stays a preset name, and `detect` rejects the class `unset`.

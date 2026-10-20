# Performance review 5: URL builder, parsing and signing

Scope: `image_pipe_url/` (building, `image_url/2`, lexing, parsing, presets, signing, source encryption) plus the places in `image_pipe` that re-read the raw URL on every request or every `400`: `ImagePipe.Telemetry.request_path/2` and the diagnostic path in `ImagePipe.Plug.Errors`. Reviewed at `main` fe70ecc. No code was changed; one what-if patch was applied, measured, tested and reverted. Paths are relative to the repository root.

## How this was measured

- Elixir 1.20.4, OTP 29 (JIT), shared cloud vCPUs, `MIX_ENV=dev`, compiled code. Expect ±10–20% noise between runs on this machine.
- Microbenchmarks: a loop calling the real public functions, best of 3 runs, µs per call.
- `tprof` call-time profiles to look for hot spots.
- Wire-level checks through `ImagePipe.Plug.call/2` (Plug.Test conns, no telemetry handlers attached, file source).

## Perf review 4 findings: status on main

| Perf review 4 finding | Bead | Status |
| --- | --- | --- |
| 1. Telemetry path redaction cubic in `wm-src64=` segments | image_plug-98ui | Fixed (1bb703b, "Keep request_path redaction linear and decode escaped base64"). `request_path/2` on 4,900 `/a` segments (9.8 KB) is now 0.6 ms, on 1,100 `/wm-enc=A` segments 0.09 ms, on a typical path 6 µs. |
| 2. Two to five `~r` regexes per request in redaction | image_plug-98ui | Fixed in the same commit: no `~r` or `Regex` left in `telemetry.ex`. The only `~r` left in `image_pipe_url/lib` is `url/config.ex:208`, which runs at configuration time. |
| 3. Parse cost about 7.5 µs per group (informational) | none | Unchanged, as expected: 32 `blur` groups parse in 214–290 µs. Finding 1 below takes a third of that away. |

Current baseline for the same two-group URL earlier passes used (`/sig=…/w=400/h=300/fit=cover/anchor=smart/sharpen=0.5/-/blur=2/format=webp/q=82/src/https%3A…`), three runs:

| Operation | Perf review 4 | Now |
| --- | --- | --- |
| `split_signature` + `verify` + `extract` + `parse` | 27 µs | 29–37 µs (verify 2.5, extract 6.5–8, parse 17–21) |
| Builder: `new |> group |> group |> output |> url!`, signed | 14 µs | 13–16.6 µs |
| `url!/3` alone | 5.9 µs | 6.7–8.7 µs |
| `url!/3` with `validate_against` (20 presets, request defaults) | 21–24 µs | 19.6–20.5 µs |
| `url!/3` with `encrypt_source` | 18.5 µs | 13.6–16 µs |
| `Helpers.__url__/5` with a stored config | 12 µs (`instance:`) | 16.5–17.7 µs (`config:` MFA reading `:persistent_term`) |

The request side looks a few µs slower than in pass 4, but within this machine's run-to-run noise; the profile shows no new hot spot. Changes since pass 4 in this area (error-message texts, `Source.check/1` in the builder, preset renumbering, `uniform_weight`, zero-origin regions) add nothing measurable: `Presets.renumber/2` runs on an empty `ignored` list for a clean URL.

## Findings, ranked by payoff against risk

### 1. Every parse runs the full preset expansion, even with no preset in the URL and no request defaults

- **Severity:** Low–Medium. Measured, with a what-if patch. About a quarter of each parse on the common path.
- **Where:** `image_pipe_url/lib/image_pipe/api/parser.ex:377-420` (`expand_presets/5`) calls `Presets.expand/4` (`image_pipe_url/lib/image_pipe/plan/presets.ex:126`) unconditionally. With no presets selected it still goes through `compose/4` and `compose_groups/4` (`presets.ex:214-246`), which runs `merge_layers/1` (`presets.ex:292`) twice per group (once to find the first non-empty group, once to merge), each `merge_group/2` pruning every override family (`family -- @family_modifiers` is recomputed per family per merge, `presets.ex:378`), then `drop_unset/1` per group. Back in the parser it rebuilds `new_index`, re-maps every occurrence through `new_group_index/2`, and builds the synthetic occurrence list, all of which are identities when nothing was expanded.
- **Evidence:**
  - `Presets.expand/4` alone, no presets, no defaults: 3.6–3.8 µs for the two-group request, 33 µs for 32 groups.
  - What-if: skip expansion when the config has no `:request_defaults`, no group has `:presets`, no group is empty, and no value is `:unset` or `{:unset, _}` (then expansion is an identity with `origins` = `%{i => i}`). Parse of the two-group URL went from 21–26 µs to 14–18 µs in alternating runs (the machine was noisy that hour; the earlier 17 µs baseline run puts the saving at about 4–5 µs). 32 `blur` groups went from 214–250 µs to 156–161 µs. All 650 `image_pipe_url` tests passed with the patch. The patch was reverted.
- **Suggested fix:** a guarded fast path at the top of `expand_presets/5` with exactly those conditions, returning `{groups, request, [], occurrences, identity_origins}`. The conditions are cheap (one pass over the group maps). If the fast path feels too clever, the cheaper half is inside `Presets`: compute `family -- @family_modifiers` at compile time and merge each group's layers once in `compose_groups/4`.
- **Question for Håvard:** does your server deployment set `request_defaults`? With defaults configured, every request merges them into the first group, so this fast path never applies there. If that's the common case, the compile-time and merge-once changes are the ones worth doing, and the payoff is closer to 1–2 µs.

### 2. The `400` diagnostic path walks and copies every segment of the raw path, uncapped

- **Severity:** Low. Measured, including through `ImagePipe.Plug.call/2`. Reachable without a valid signature only on mounts without signing keys (or with a `sig=` on a mount without keys); on signed mounts a `400` needs a valid signature first.
- **Where:** `image_pipe_url/lib/image_pipe/api/path.ex:350-386` (`redact_secrets/3`, `mask_bytes/3`), called by `Path.diagnostic_path/1` from `image_pipe/lib/image_pipe/plug/errors.ex:93` for every `{:invalid_request, _}` and `:signature_without_keys` response.
- **What it does:** `redact_secrets/3` steps through the path with `split_first_segment/1` (`path.ex:103-108`), which returns the remainder as `"/" <> rest`, a fresh copy of the rest of the path for each segment. That is quadratic in the number of segments. Unlike the lexer, which stops after 64 option segments, it runs to the end of the path. Each `sig=` or `wm-enc=` segment also rebuilds the whole path in `mask_bytes/3`. The result then goes to `DiagnosticRenderer.render/2`, which echoes only the first 2,048 bytes (`diagnostic_renderer.ex:25,69-70`).
- **Evidence:**

  | Path | Size | `diagnostic_path/1` | `Path.extract/2` | `Telemetry.request_path/2` | whole `Plug.call` (status 400) |
  | --- | --- | --- | --- | --- | --- |
  | `/w=bad/src/a.jpg` | 16 B | <1 µs | | | 37 µs |
  | typical two-group URL | 140 B | 4 µs | 12 µs | 6 µs | |
  | 1,000 × `/a` | 2.0 KB | 0.29 ms | | | |
  | 4,900 × `/a` | 9.8 KB | 1.86 ms | 0.055 ms | 0.61 ms | 4.4 ms |
  | 1,100 × `/wm-enc=A` | 9.9 KB | 0.89 ms | 0.052 ms | 0.09 ms | 2.6 ms |
  | 1,650 × `/sig=A` | 9.9 KB | 1.49 ms | | | |

  A 10 KB request (inside Bandit's default 10,000-byte request line) costs the diagnostic redaction 30× what the lexer spends on it, and about three warm cache hits of CPU. It is bounded by the request-line limit, so this is not a DoS on its own, but it is the largest remaining per-request cost an unauthenticated client can pick on an unsigned mount.
- **Suggested fix:** walk the path by offset instead of by copied remainders (`:binary.matches(path, "/")` once, or a recursive scan with a byte offset), and build the masked result as iodata in one pass. Also stop at the renderer's 2,048-byte echo limit: nothing past it is shown. If the cut lands inside a `sig=`/`wm-enc=` value or an `enc/` tail, mask from that segment's start, which the offset walk knows. The same `"/" <> rest` copy is in the lexer's `split_first_segment/1`, where the 64-segment cap bounds it; switching both to offsets keeps them alike.

### 3. `src` percent-escape validation is ten times slower than the decode it guards

- **Severity:** Low. Measured. Typical sources are unaffected (about 1 µs); long sources with many escapes cost up to 0.5 ms per request.
- **Where:** `image_pipe_url/lib/image_pipe/api/path.ex:299-320` (`percent_decode/1`, `malformed_percent?/1`), then `URI.decode/1`.
- **What it does:** `malformed_percent?/1` finds each `%` with `:binary.match/2`, then takes a `binary_part/3` of the rest and recurses: one BIF call and one sub-binary per escape. `URI.decode/1` then walks the string again byte by byte, including the stretches with no escapes.
- **Evidence:** per call, with the current check plus `URI.decode/1` against a single byte-loop that checks and decodes together (`<<?%, a, b, rest::binary>> when hex?(a) and hex?(b)` → append the byte, `<<?%, _::binary>>` → `:error`, anything else → append) and returns the input unchanged when `:binary.match(value, "%")` is `:nomatch`:

  | `src` tail | current | one pass |
  | --- | --- | --- |
  | typical 60 B URL with 8 escapes | 1.78 µs | about 0.5 µs |
  | 8 KB, all escapes (`%E7%8C%AB`…) | 459 µs (check 337, decode 46) | 43 µs |
  | 8 KB, one escape per 10 bytes | 172 µs | 54–60 µs |
  | 8 KB, no escapes | 68 µs (all in `URI.decode`) | 0.2 µs |

  Through the Plug, `/w=bad/src/<8 KB of escapes>` takes 1.09 ms to its `400`, of which `Path.extract/2` is 0.54 ms. A signed mount verifies before lexing, so there only a correctly signed long URL pays it. A `:binary.split(value, "%", [:global])` variant was also tried: fast for few escapes (0.2 µs with none) but 214 µs for all-escapes, so the byte loop with the `:nomatch` shortcut is the better shape.
- **Suggested fix:** replace `percent_decode/1`'s two passes with the single byte loop plus the no-`%` shortcut. Both malformed-escape and decode behaviour stay the same (the what-if returned identical results to the current code on all four inputs and on `%`, `a%2`, `%zz`, `ok%2Fx%G1`). Small enough to fold into finding 2's change, since both touch `path.ex`.

## Checked and found fine

- **Telemetry redaction after the 98ui fix:** linear. 0.6 ms for 4,900 segments (0.12 µs per segment), 6 µs for a typical path, 88–141 µs for an 8 KB `src`.
- **Builder chain:** 13–16.6 µs signed, profile flat: the largest entries (`Keyword.keys/1`, `Enum.map`, `lists:keyfind`, `Access.get`) are each under 4% of the total. Schemas are compiled once (`Builder.Options.compiled/2`). Nothing worth changing.
- **`url_with_issues/3`** (what `image_url/2` calls): 7.6–9 µs, about 1 µs over `url!/3`.
- **`image_url/2` without `:config` or `:instance`:** `ImagePipe.URL.config([])` runs per URL, 2.2 µs. Small; documented behaviour.
- **`validate/1`:** 0.06 µs.
- **Signature verification:** 2.5 µs; three keys with the match last 5.6–6.2 µs, linear in keys.
- **Source encryption on the builder:** `url!/3` 13.6–16 µs against 6.7–8.7 plain.
- **Lexer with 63 option segments:** 45 µs, bounded by the 64-segment cap; with a 9 KB plain `src` 111 µs, all of the extra in `URI.decode/1` (finding 3).
- **`DiagnosticRenderer.render/2`:** capped at 16 diagnostics and 2,048 echoed bytes; 1–21 µs on every shape tried.
- **Regexes:** none left on any request or build path in `image_pipe_url` (only `url/config.ex:208`, at configuration time).

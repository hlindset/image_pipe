# Performance review 4: URL builder, parsing and signing

Scope: `image_pipe_url/` (URL building, the `image_url/2` helper, lexing, parsing, presets, signing, source encryption), plus the one place `image_pipe` re-reads the URL grammar on every request: the telemetry path redaction in `ImagePipe.Telemetry.request_path/2`. Reviewed at `main` 8edf03b8. No code was changed; one what-if patch was applied, measured, and reverted. Paths are relative to the repository root.

## How this was measured

- Elixir 1.20.4, OTP 29 (JIT), shared cloud vCPUs, `MIX_ENV=dev`, compiled code. Expect about ±10% noise.
- Microbenchmarks: a loop calling the real public functions, best of 3 runs, µs per call. Single-shot `:timer.tc` for the multi-millisecond cases.
- `tprof` call-time profiles to look for hot spots.
- One wire-level check through `ImagePipe.Plug.call/2` with no telemetry handlers attached.

## Earlier findings: all fixed on main

Every item perf review 3 filed for this area is fixed, and the numbers show it:

| Perf review 3 finding | Bead | Fixed by | Then | Now |
| --- | --- | --- | --- | --- |
| 1. `config:` helper rebuilt the configuration per URL | e4a.15.15 | 7280e65f (docs now cache it in `:persistent_term`) | 39–401 µs per URL | 12 µs (`__url__` with a stored config) |
| 2. NimbleOptions re-validated keyword schemas per option | e4a.15.16 | a67aeffc | builder chain 47 µs | 14 µs |
| 3. Module-attribute regexes re-imported per match | e4a.15.14 | 3d1b2f36 | about 8 µs of each parse | gone from `image_pipe_url` (one `~r` left in `url/config.ex:208`, config time only) |
| 4. Serializer scanned all 70 specs per group | e4a.15.17 | ea4d0f4c | `url!` 17.7 µs | 5.9 µs |
| 5. `OptionSpec.fetch/1` linear search | e4a.15.18 | ec6e2a91 | | map compiled into the parser (`api/parser.ex:31`) |
| 6. Worst-case 64-segment parse (informational, not filed) | none | partly, as a side effect | 367 µs | 247 µs (see finding 3 below) |

Current baseline for the same two-group request perf review 3 used (`/sig=…/w=400/h=300/fit=cover/anchor=smart/sharpen=0.5/-/blur=2/format=webp/q=82/src/https%3A…`):

| Operation | Perf review 3 | Now |
| --- | --- | --- |
| `split_signature` + `verify` + `extract` + `parse` | about 50 µs | 27 µs (verify 2.1, extract 6.2, parse 14.9) |
| Builder: `new |> group |> group |> output |> url!`, signed | 47 µs | 14 µs |
| `url!/3` alone on a built plan | 17.7 µs | 5.9 µs |
| `url!/3` with `validate_against` (20 presets, request defaults, watermarks) | 37 µs | 21–24 µs |
| `image_url/2` with `instance:` (`ImagePipe.url_config/2` is 0.7 µs) | not measured | 12 µs |

## Findings, ranked by payoff against risk

### 1. Telemetry path redaction is cubic in the number of `wm-src64=` segments, and runs on every request before the signature check

- **Severity:** High. Measured, including through `ImagePipe.Plug.call/2`. Unauthenticated: one request can burn seconds of CPU on a signed mount.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:318-331` (`redact_segment_list/1`), called from `request_path/2` (`telemetry.ex:299-300`) for the `[:request]` span's start metadata at `image_pipe/lib/image_pipe/plug/runner.ex:27,46-48`. Added with dd8bc4d1 ("Redact presigned credentials in watermark sources too", 2026-10-15).
- **What it does:** for each `wm-src64=<token>` segment, it tries joining the token with 0, 1, … up to *all* remaining segments (`Enum.find(0..length(rest)//1, …)`), and for each join calls `base64_presigned?/1`, which runs a regex replace and up to six base64 decodes of the joined string. Each join is O(n) in the remaining path, there are O(n) joins per `wm-src64=` segment, and every segment can be one, so the work is O(n³) in segment count. It runs on the raw path before `Path.extract/2` (so the lexer's 64-option-segment cap doesn't apply) and before `Security.verify/3`. `request_metadata(conn)` is evaluated eagerly, so it runs whether or not any telemetry handler is attached.
- **Evidence:**

  | Path | Size | `request_path/2` |
  | --- | --- | --- |
  | normal `/w=400/…/src/https%3A…` | 90 B | 3.2 µs |
  | one `wm-src64=<22-char token>` + 8 option segments | 0.1 KB | 64 µs |
  | one `wm-src64=` + 62 short segments | 0.3 KB | 0.5 ms |
  | 63 × `wm-src64=<22-char token>` | 2.3 KB | 24 ms |
  | 250 × `wm-src64=A` | 2.8 KB | 317 ms |
  | 250 × `wm-src64=<22-char token>` | 9.0 KB | 281 ms |
  | 500 × `wm-src64=A` | 5.5 KB | 1.68 s |
  | 900 × `wm-src64=A` | 9.9 KB | **6.8 s** |
  | one `wm-src64=A` + 2,400 × `w=1` | 9.6 KB | 106 ms |

  Through the Plug, unsigned requests on a mount with signing keys and no handlers attached: 63 × `wm-src64=A` returned 403 after 29 ms, 250 after 339 ms, 500 after 1.5 s. Bandit's default request-line limit is 10,000 bytes (`max_request_line_length`; the server's `http_child/2` in `image_pipe_server/lib/image_pipe_server/application.ex:187-200` doesn't change it), so the 9.9 KB, 6.8 s case fits in one request. The work runs in the request process, so a handful of such requests in parallel ties up every scheduler. Nothing in the 403 path, the 64-segment cap, or `max_connections` limits it.
- **What-if:** limiting the join to at most 63 following segments, and stopping at the first segment that isn't standard base64 (only `A-Z a-z 0-9 +`, with optional trailing `=`), took 900 × `wm-src64=A` from 6.8 s to 3.8 ms, one `wm-src64=` + 2,400 × `w=1` from 106 ms to 0.3 ms, and the worst all-base64 shapes (`wm-src64=A` followed by 1,900 × `AAAA`, or 450 × `wm-src64=A/AAAAAAAAAAAAAAAA`) to 2–4 ms. `telemetry_test.exs` and `telemetry/summary_test.exs` (49 tests, including the redaction ones) still passed. The patch was reverted.
- **Suggested fix:** in `redact_segment_list/1`, only extend a `wm-src64=` token over following segments that could be standard-base64 continuations (the alphabet above, `=` only at the end), and never over more than the lexer's `@max_option_segments` (`image_pipe_url/lib/image_pipe/api/path.ex:27`). That bounds each token to 64 joins of at most 64 segments and makes typical paths linear. Two further options, which can be combined with it:
  - Stop redacting option segments past the first 64, since the request is rejected as `:too_many_segments` anyway, or redact the whole path to `REDACTED` when it has more option segments than the lexer accepts.
  - Decode each candidate once, growing the joined string incrementally, instead of `Enum.join` over a fresh `Enum.take` per candidate.
- **Related:** bug hunt 5's request-handling finding 4 (`bug-hunt-5/request-handling.md`) is a correctness gap in the same function: percent-encoded `src64`/`wm-src64` spellings escape redaction. Its fix would add more spellings per candidate, which multiplies this cost, so the two should be fixed together.
- **Question for Håvard:** the lexer splits on `/`, so a `wm-src64=` value containing a standard-base64 `/` never parses as a watermark source. Is redacting the joined spelling still needed, given such a request is always a 400? If not, checking the single segment is enough and removes the join loop entirely.

### 2. Every request runs two to five regexes for telemetry redaction, re-imported each time

- **Severity:** Low. Measured.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:305` (`Regex.run(~r{\A(.*?/)(src|src64|enc)/(.*)\z}s, path)` on every request), `telemetry.ex:355` (`String.replace(token, ~r/…/)` per `src64` candidate), `telemetry.ex:376` (`String.split(query, ~r/(?<=[&;])/)` for each query string and each decoded `src` URL with a query).
- **Evidence:** on OTP 28+, a `~r` literal is re-imported per use, the pattern perf review 3 fixed in `image_pipe_url` (e4a.15.14). `request_path/2` costs 3.2 µs for a plain `src` path, 7.2 µs for `src64`, and 14.9 µs for a presigned `src` URL; the `Regex.run` alone is 2.1 µs of the 3.2. Bead e4a.15.14's fix didn't reach this file because the code arrived after it (dd8bc4d1).
- **Suggested fix:** find the source marker with a binary scan for `/src/`, `/src64/` or `/enc/` (the lexer in `image_pipe_url/lib/image_pipe/api/path.ex` already does this), split the query with `:binary.split(query, ["&", ";"], [:global])` keeping separators by position, and strip the extension with a byte scan. This saves about 2–10 µs per request, small next to a warm hit, so fold it into finding 1's change rather than doing it alone.

### 3. Parse cost grows by about 7.5 µs per group; worst case about 250 µs

- **Severity:** Low (informational). Measured. Follows up perf review 3's finding 6, which wasn't filed.
- **Where:** per-group work in `image_pipe_url/lib/image_pipe/plan/spec.ex:142-176` (`assemble_group/1`, 2.9 µs own time per group under `tprof`) and `image_pipe_url/lib/image_pipe/plan/spec/validation.ex:98-196` (`requirements/3` builds about 25 rule tuples per group with repeated `invalid?/3` and `resize_intent?/1` scans).
- **Evidence:** `extract` + `parse` of `blur=N` groups: 1 group 7.0 µs, 2 groups 15.0, 4 groups 29.7, 8 groups 48.9, 16 groups 121, 32 groups 247 µs. It is linear, not quadratic. Other 64-segment shapes: 21 groups of `w`+`blur` 223 µs, 64 duplicate `blur` 132 µs, 64 unknown keys 89 µs, 64 invalid `w` values 99 µs. The lexer caps option segments at 64, and on a signed mount parsing runs only after the signature checks out.
- **Suggested fix:** none needed. If `Validation` is touched for other reasons, compute `resize_intent?` and the invalid-key set once per group and pass them down instead of re-scanning per rule.

## Checked and found fine

- **Builder chain** (`ImagePipe.URL.new/group/output/url!`): 14 µs signed. `tprof` shows no hot spot left; the largest own-time entries are `Builder.Options.last_values/3` and `collect/4` at under 1 µs per call.
- **`url!/3` variants:** plain 14.5–16 µs, with 20-preset `validate_against` 21–24 µs, with `encrypt_source` 18.5 µs, a single `presets: ["thumb"]` group 11.8 µs. `validate/1` alone 5.8 µs.
- **`instance:` helper route:** `ImagePipe.url_config/2` reads `:persistent_term` and drops refused cache roots with one `:ets.member/2`: 0.7 µs. `Helpers.__url__/5` end to end 12 µs.
- **Signature verification:** 2.1 µs; with three keys and the match last, the whole request side is unchanged within noise (34.0 against 34.7 µs).
- **Source decryption:** the encrypted-source request side is 36.6 µs against 34.7 µs plain.
- **Presets on the request side:** a request using `preset=thumb` with request defaults and 20 static presets parses in 25.8 µs. Request-time lookup re-parses and compiles each fetched fragment per request (`image_pipe/lib/image_pipe/presets.ex:121-136`), but that is 9–13 µs per fragment, small next to the lookup itself.
- **Configuration build:** `ImagePipe.URL.config/1` with 20 presets is 277 µs, and with the documented caching it runs once.
- **Lexing** (`api/path.ex`): 6.2 µs for a 10-segment path, spread across `binary:split/2`, `binary:match/2` and percent-decoding, with no hot spot.

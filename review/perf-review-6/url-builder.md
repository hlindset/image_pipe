# Performance review 6: URL builder, parsing and signing

Scope: `image_pipe_url/` (building, `image_url/2`, lexing, parsing, presets, signing, source encryption) plus the code in `image_pipe` that works on the raw URL or the parsed source on every request: `ImagePipe.Plug.Request`, `ImagePipe.Telemetry.request_path/2` and `source_url/1`, the `400` diagnostic path in `ImagePipe.Plug.Errors`, and request-time preset lookup (`ImagePipe.Presets`). Reviewed at `main` 6a87579. No code was changed: two what-if patches were applied, tested, measured and reverted. Paths are relative to the repository root.

## How this was measured

- Elixir 1.20.4, OTP 29 (JIT), shared cloud vCPUs, `MIX_ENV=dev`, compiled code.
- This machine was slower and noisier than in pass 5: the same benchmark ran 1.5–2× slower than pass 5's numbers, and single runs moved by ±30%. To tell a regression from noise, the pass-5 commit (fe70ecc) was built in a second worktree and benchmarked in alternating runs against main. Compare numbers within this report, not with pass 5's.
- Microbenchmarks: a loop over the real public functions, best of 3, µs per call. `tprof` call-time profiles for hot spots.
- Wire-level checks through `ImagePipe.Plug.call/2` (Plug.Test conns, no telemetry handlers attached, `ImagePipe.Source.File` source, missing file so every request ends in `404` after a full parse).

## Perf review 5 findings: status on main

| Perf review 5 finding | Status |
| --- | --- |
| 1. Every parse runs the full preset expansion | Fixed (72a0ccd, "Skip preset expansion when a parse has nothing to expand"). `expand_presets/5` returns early when there are no request defaults, presets, empty groups, or unsets, and `Presets` computes the family principals at compile time and merges each group once. With request defaults configured, parse costs 2–5 µs more than without, in line with the expected 1–2 µs at pass-5 speed. |
| 2. `400` diagnostic path walks and copies every segment | Fixed (6c4a18c, "Keep path redaction linear on crafted paths"). `Path.diagnostic_path/1` now walks by byte offset (`secret_ranges/3`) and masks in one iodata pass. |
| 3. `src` percent-escape validation slower than the decode | Fixed (69e6358, "Check and decode src escapes in one pass"). `percent_decode/1` is the single byte loop with the `:nomatch` shortcut. |

Current baseline, alternating runs of main and fe70ecc on this machine (µs per call):

| Operation | fe70ecc (pass 5) | main |
| --- | --- | --- |
| `split_signature` + `verify` + `extract` + `parse`, the two-group signed URL from pass 5 | 44–47 | 27–32 |
| `parse` alone | 24–37 | 19–24 |
| `parse`, 32 `blur` groups | 161–205 | 152–169 |
| Builder chain + `url!/3`, signed | 28–33 | 22–29 |
| `url!/3` | 13–14 | 11–19 |
| `url_with_issues/3` | 16–21 | 15–24 |
| `image_url/2` with `config:` MFA | | 15–18 |
| `image_url/2` with `instance:` (checks against the instance's presets) | | 27–28 |

No regression in `image_pipe_url`. The parser profile is flat (no function over 6% exclusive). One regression is in the `image_pipe` side of this area: finding 1.

## Findings, ranked by payoff against risk

### 1. `Telemetry.source_url/1` runs on every parsed request, costs up to the parse itself, and is quadratic-looking on control characters

- **Severity:** Low–Medium. Measured, with a what-if patch. New since pass 5: it came in with 1354270 ("Cut the logged path at the source and log the source parsed"), which also brought back the two `~r` regexes on the request path that pass 4's fix had removed.
- **Where:** `image_pipe/lib/image_pipe/telemetry.ex:325-336` (`source_url/1`), `:350-370` (`redact_params/2`, `redact_param/1`, `credential_param?/1`); called from `image_pipe/lib/image_pipe/plug/request.ex:49-56` (`source_metadata/2`) for the source and every watermark source of every request that parses, whether or not any telemetry handler is attached.
- **What it does:** for every source, `String.replace_invalid/1` walks the string byte by byte in Elixir, then `Regex.replace(~r/[\x00-\x1F\x7F]/, …, fn …)` runs, then the userinfo regex runs on the base, then each query parameter name goes through `URI.decode/1` and a full Unicode `String.downcase/1`. On OTP 28+ each inline `~r` also pays `re:import/1` per call (about 1.2 µs each in the profile). A control character in the source costs a regex match, a callback, and `Base.encode16/1`: about 1 µs each.
- **Evidence:**

  | Source | `source_url/1` now | with the what-if |
  | --- | --- | --- |
  | `images/cat.jpg` | 4.5–6.8 µs | 0.4–0.9 µs |
  | `https://example.com/images/cat.jpg?v=2` | 7.7–11 µs | 2.3–2.6 µs |
  | presigned S3 URL (6 query parameters) | 26–29 µs | 14–15 µs |
  | 8 KB plain source | 81–105 µs | 16–17 µs |
  | 8 KB, 4,000 control bytes | 3.5–4.3 ms | unchanged (slow path) |

  For comparison, the whole verify + lex + parse of the two-group URL is 27–32 µs, so a presigned source more than doubles the URL work of a request. Profile of the presigned case: `String.do_replace_invalid/3` 28%, `String.Unicode.downcase/3` 11%, `URI.unpercent/3` 9%, regex internals most of the rest.

  Through `ImagePipe.Plug.call/2` on an unsigned mount, a request whose source holds control characters costs milliseconds before the source is even looked up (status 404 here):

  | Request | size | `Plug.call` |
  | --- | --- | --- |
  | `/w=400/src/images/missing.jpg` | 29 B | 170–180 µs |
  | `/w=400/src/` + 9,600 × `a` | 9.6 KB | 530–880 µs |
  | `/w=400/src/` + 2,400 × `a%01` | 9.6 KB | 3.4–3.9 ms |
  | `/w=400/src64/` + base64 of 3,600 × `a\x01` | 9.6 KB | 5.4–5.8 ms |

  In the last two rows the profile puts 60%+ in the control-character `Regex.replace/4` (`re:internal_run/4`, `Regex.apply_list/5`, `Base.encode16/2`). It is linear, with a high constant, so the 10,000-byte request line bounds it. On a signed mount only a correctly signed URL reaches it. It is now the largest per-request cost an unauthenticated client can pick on an unsigned mount, in the same range as pass 5's diagnostic-path finding (4.4 ms through the Plug, on a faster machine) that 6c4a18c fixed.
- **What-if patch (tested, reverted):** skip the slow work when it cannot change anything. All 220 tests in `test/image_pipe/telemetry` passed with it.

  ```elixir
  def source_url(source) do
    source =
      if printable_ascii?(source),
        do: source,
        else: source |> String.replace_invalid() |> then(&Regex.replace(~r/[\x00-\x1F\x7F]/, …))
    …
    base =
      if :binary.match(base, "@") == :nomatch,
        do: base,
        else: Regex.replace(~r{\A((?:[A-Za-z][A-Za-z0-9+.-]*:)?//)[^/]*@}, base, "\\1REDACTED@")
    …
  end

  defp credential_param?(name) do
    if printable_ascii?(name) and :binary.match(name, "%") == :nomatch,
      do: String.downcase(name, :ascii) in @credential_params,
      else: String.downcase(URI.decode(name)) in @credential_params
  end

  defp printable_ascii?(<<c, rest::binary>>) when c in 0x20..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(_other), do: false
  ```

  The fast paths give exactly the old result: a printable-ASCII string is valid UTF-8 with no control bytes, the userinfo regex needs an `@`, and for an ASCII name without `%`, `URI.decode/1` is the identity and `:ascii` downcasing equals full downcasing.
- **Suggested fix:** the patch above, plus a faster slow path for sources that do hold control bytes: one byte walk that copies untouched runs as sub-binaries and looks up `"%00"`…`"%1F"`, `"%7F"` from a tuple instead of calling `Base.encode16/1`. In isolation that took the 4,000-control-byte escape from 2.8–4.0 ms (current regex) to 0.27–0.31 ms with identical output on the test inputs (with `Base.encode16/1` kept in the walk it was 1.2 ms, so the lookup matters). `String.replace_invalid/1` on the same input is 70–95 µs and can stay. `redact_param/1` could also use `:binary.split/2` instead of `String.split/3`, which is most of the 14 µs left on the presigned case.
- **Question for Håvard:** should the parse stop metadata be computed only when a handler is attached to `[:parse, :stop]` (`:telemetry.list_handlers/1`)? The Logger and tracer both read it, so it would usually be attached in the server, and the fix above makes it cheap enough that the gate may not be worth the extra branch. Note that the request-path perf thread may report the same function, since it sits in `Plug.Request`.

### 2. Very long numeric values cost about 0.3–0.7 ms to reject

- **Severity:** Low. Measured. Bounded by the request line; only unsigned mounts let a client choose it freely.
- **Where:** `image_pipe_url/lib/image_pipe/api/value.ex:22-41` (`number/1`: `String.to_integer/1` or `String.to_float/1` on the whole digit string), `:79-89` (`dimension/1`), `image_pipe_url/lib/image_pipe/api/option_spec.ex:540-551` (`positive_decimal/1`: `Float.parse/1`), `:597-611` (`decimal_ratio/1`: `Integer.pow(10, String.length(fraction))` and a bignum multiply), `:613-623` (`integer_ratio/2`). Every numeric option converts the full digit string to a number before the range check rejects it, and a decimal `crop-ratio` builds a bignum ratio and its GCD first.
- **Evidence:** lex + parse of one URL, µs per call:

  | Value | parse |
  | --- | --- |
  | `crop=50pct,50pct/crop-ratio=16:9` | 14.7 |
  | `w=` + 9,900 digits | 584 |
  | `blur=` + 9,900-digit integer | 587 |
  | `blur=0.` + 9,900 digits | 307 |
  | `zoom=1.` + 9,900 digits | 725 |
  | `crop-ratio=1.` + 9,800 digits | 575 |
  | `crop-ratio=<4,900 digits>:<4,890 digits>` | 513 |

  In isolation: `String.to_integer/1` on 9,900 digits 246 µs, `Value.number/1` 360 µs, `Float.parse/1` on a 9,900-digit decimal 213 µs, `Integer.pow(10, 9800)` 59 µs. `Integer.gcd/2` on two ~5,000-digit numbers is only 4 µs, so the ratio cost is the conversions, not a slow GCD. Conversion is superlinear in length, so splitting the digits over several segments costs less than one long value: one value near the request-line limit is the worst case, about 40× a normal parse. That is under finding 1's worst case, so it ranks below it.
- **Suggested fix:** reject a numeric token whose length can't be in range before converting it. An integer option's largest value is 2,147,483,647, so more than 10 significant digits (after leading zeros) is always out of range. Decimals need care: `blur=0.000…01` with a very long fraction is a valid (tiny) number today.
- **Question for Håvard:** is a length cap on numeric tokens, say 32 bytes, an acceptable grammar change? It would turn absurd spellings such as `blur=2.000…0` with 100 zeros from accepted into `400`. If not, the cap can apply to integer parts only (significant digits beyond 10 are always out of range for every option), which keeps every accepted URL accepted and removes the `w=`, `crop-ratio` and integer cases; the long-fraction decimal cases (300–700 µs) would remain.

### 3. Request-time preset lookup parses and compiles every looked-up fragment on every request

- **Severity:** Low. Measured. Only mounts with `:preset_lookup`, only requests that name a looked-up preset.
- **Where:** `image_pipe/lib/image_pipe/presets.ex:21-48` (`for_request/2`) and `:50-60` (`resolve/2` → `fetch_levels/3` → `parse/1` → `compile/2`), which call `ImagePipe.API.Presets.parse_fragment/1` (`image_pipe_url/lib/image_pipe/api/presets.ex:40`) and `compile_lookup/2` (`:53`, `Presets.compile/2` plus `check_conflicts/3`) for each fetched name, on every request. `ImagePipe.PresetLookup`'s moduledoc tells hosts to cache `fetch/2` results, but the host can only cache the fragment strings, so this work repeats even on a host cache hit.
- **Evidence:** `Presets.for_request/2` with an in-memory lookup that returns fragments from a module attribute (so the host side costs nothing): 13–18 µs for one preset (`card`, 7 options), 28–32 µs for `card,soft`, 26–33 µs for a nested `hero → card`. The request's own `Parser.parse/2` with the compiled preset is 13–14 µs, so a looked-up preset more than doubles the URL work. The extra `Parser.preset_names/1` option pass that lookup mounts run before parsing is 2–4 µs; not worth changing.
- **Suggested fix:** memoize compiled lookups by their inputs: the static preset map is fixed per configuration, so a looked-up name's compiled preset depends only on the fragment strings fetched for it and its looked-up references. A small per-instance table keyed by `{name, fragment}` for leaf presets (and by the sorted set of `{name, fragment}` pairs for nested ones) gives the same result without reparsing. Changing a definition changes the fragment and so misses the memo, which keeps the current "a new definition applies to the next request" behaviour. It needs a bound (size or LRU) since names come from requests; `:max_preset_lookups` bounds names per request, not over time.
- **Question for Håvard:** is lookup used in your deployments? If not, this can wait; the gain is about 15 µs per looked-up preset per request.

## Checked and found fine

- **Signature verification:** 2.4–3.9 µs for one key, unchanged in shape.
- **Lexer (`Path.extract/2`):** 12–14 µs for the 140-byte two-group URL on this machine, flat profile. The `segments_acc ++ [...]` append in `lex_segments/5` is quadratic but bounded by the 64-segment cap.
- **Parser at the segment cap:** 32 groups 152–231 µs, 21 groups × 2 options 126–226 µs (noise dominates). `collect_duplicate_errors/2` and `build_clean_group_maps/2` filter all occurrences once per group (O(groups × segments)); in the 32-group profile their filters are about 20% of the parse. A what-if that groups occurrences once with `Enum.group_by/2` passed all 661 `image_pipe_url` tests, but its timings (126–207 µs against 144–184 µs) didn't separate from the noise in alternating runs. Not worth a change unless a quieter machine shows the 20%.
- **Preset expansion with request defaults:** 21–28 µs against 19–24 µs without defaults; the pass-5 fix holds.
- **`Telemetry.request_path/2`:** 1.1–1.4 µs for a typical path, linear (`String.split/2` and one pass).
- **`ImagePipe.url_config/2` per `image_url/2` call with `instance:`:** 0.9 µs (`NimbleOptions` on an empty list and a `:persistent_term` read). The rest of the `instance:` premium over `config:` (about 11 µs) is the semantic check against the instance's presets, which is the documented behaviour.
- **Source encryption:** keys are derived once in `SourceEncryption.new/2`; decrypt is one HMAC-SHA512 and one AES-CBC call per token.
- **`mount_relative_path/1`:** computed three times per request (runner metadata, parse, error rendering) but each is a sub-binary walk over the mount's segments only; not measurable.

## Outside this area, seen in passing

- A request that parses and then misses a file source costs 170–180 µs through `Plug.call/2`, against about 30 µs of URL work. About 10% of the profile is `Keyword.take/2` filtering the full configuration keyword list, with about 190 key checks per request, through `ImagePipe.Telemetry.telemetry_opts/1` (`image_pipe/lib/image_pipe/telemetry.ex:509`, once per span) and other `Keyword.take/2` calls on the config. That belongs to the request-path review; noted here so it isn't lost.

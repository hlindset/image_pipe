# Bug hunt 4: URL builder

Area: `image_pipe_url`, which covers URL generation, the option grammar and parser, presets and request defaults, `Plan.Spec` canonical form, signing, source encryption, and the `image_url/2` helper. The checks ran against `main` at `db4fe3c` (0.2.0) on Elixir 1.20.4 / OTP 29. The `image_pipe_url` suite passes (631 tests, 28 properties).

## How this was checked

- **Commits since hunt 3.** I read every `image_pipe_url` commit since `259fb05`. The riskiest were the byte scanners that replaced the regexes (`3d1b2f36`), value bounds (`5b957192`), angle and number canonicalization (`f5b2f222`), the serializer reorder (`ea4d0f4c`), and the parser refactors (`6e2aff73`, `23bafb0f`).
- **Round trip.** A StreamData fuzzer ran 22,000 plans. Each plan had up to 3 groups and drew from every group option, all output and encoder options, request controls, and `:unset`. Values included edge numbers: `-0.0`, `1.0e-20`, `4.0e-324`, `2_147_483_648`, and `0.1 + 0.2`. Each plan went through `url/2`, `Path.extract/2` and `Parser.parse/2`, and the result was compared with `Plan.to_spec/1` by `term_to_binary`. Every encoder option field and value was also checked one at a time. The only mismatches are finding 4.
- **End to end.** Findings 1 and 6 were confirmed through `ImagePipe.config/1`, `ImagePipe.run/4` and `ImagePipe.validate/2` in `image_pipe`. The remaining values with no upper bound (`page`, trim tolerance, `contrast`, `saturation`, rotation, and tiny detect weights) all ran cleanly through `run/4`. A huge `page` returns `{:page_out_of_range, …}`.

## Earlier reports

Every finding in `bug-hunt-3/url-builder.md` is fixed on `main`: unbounded sizes (`5b957192`), `transparent` (`6856e9ad`), `watermark_source` vs `request_watermarks` (`8362461b`), angles just below 0 (`f5b2f222`), and the signing key minimum (`70ed99a4`).

The pushed beads (`refs/dolt/data`, pulled read only) were last updated 2026-10-05. They don't contain the hunt 3 findings. Beads `image_plug-e4a.5.2`, `.5.3`, `.5.4` and `.5.5` are still open, but `f5b2f222` fixes all four. I checked each one's repro on `main`. Only a gradient and progressive-blur residual of `.5.5` is left, which is finding 4 below.

| # | Finding | Severity |
| --- | --- | --- |
| 1 | Presets and request defaults with conflicting options pass config, then fail every request | Medium-low |
| 2 | `filename: "unset"` and `cachebuster: "unset"` vanish from the URL | Low |
| 3 | The builder accepts the detect class `"unset"`, which the server rejects | Low |
| 4 | `-0.0` survives in gradient and progressive-blur `start`/`stop` | Low |
| 5 | `pad=0` stays in the Spec as a no-op padding | Low |
| 6 | Huge float rotations and trim tolerances differ between `run/4` and the URL | Very low |
| 7 | `Issue` docs list `:invalid_offset`, which nothing returns now | Low (docs) |

---

## 1. Presets and request defaults with conflicting options pass config, then fail every request

**Severity:** Medium-low. A typo in `request_defaults` turns every request on the mount into a `400`. The configuration is accepted, so the error first shows up in traffic.

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex:74-95` (`resolve_fragment/4` composes a preset and never runs `Spec.Validation`), and `image_pipe_url/lib/image_pipe/api/presets.ex:19-25` (`compile/2`, which parses `request_defaults` through `parse_defaults/1` with no semantic check). `image_pipe/lib/image_pipe/config.ex:472` (`presets!/1`) and `ImagePipe.URL.config(validate_against: …)` both go through these.

**Evidence:** Each of these is accepted by `ImagePipe.config/1` and by `ImagePipe.URL.config(validate_against: [presets: …])`:

```text
request_defaults: "anchor=top/detect=face"         → accepted
presets: %{"p" => "q=80/autoquality=50"}           → accepted
presets: %{"p" => "w=10/h=10/extend/extend-ratio"} → accepted
presets: %{"p" => "crop=10,10/region=0,0,5,5"}     → accepted
```

At request time:

```text
defaults "anchor=top/detect=face":
  /w=5/src/x     → 400 "anchor and detect are mutually exclusive"
  /blur=2/src/x  → 400, same
  ImagePipe.run(config, group(blur: 1), …) → {:error, …}
preset p = "anchor=top/focus=0.5,0.5":
  /preset=p/src/x → 400 "anchor and focus are mutually exclusive"
```

Unknown option names and malformed values in a fragment already raise at config time. Only conflicts between options that are each valid get through. AGENTS.md reserves raises for invalid configuration, and these are configuration mistakes.

**Suggested fix:** After composing each preset and the defaults in `Presets.compile/2`, run `Spec.Validation.errors/4` on the composed groups and request map. Raise on any `:error` issue with the preset's name, as `resolve_fragment/4` already does for composition errors. Inert options can stay silent, since they're dropped when inherited.

**Question for Håvard:** A request can override a conflicting preset. With preset `p` = `anchor=top/focus=…`, `/preset=p/anchor=left/…` works, because the explicit `anchor` prunes the whole guide family from `p`. Should a preset that conflicts on its own be a config error anyway (my suggestion), or only `request_defaults`? Defaults apply to every request, so a conflict there is almost certainly a mistake.

---

## 2. `filename: "unset"` and `cachebuster: "unset"` vanish from the URL

**Severity:** Low. `cachebuster: "unset"` doesn't bust the cache, and `filename: "unset"` loses the download name. Neither gives a warning. `ImagePipe.run/4` and the served URL disagree.

**Where:** The builder accepts any path token at `image_pipe_url/lib/image_pipe/plan/builder/values.ex:166` (`normalize(_, :path_token)`), and `Plan.to_spec/1` keeps it. The parser turns the value `unset` into the `:unset` marker for every key except `preset` at `image_pipe_url/lib/image_pipe/api/parser.ex:224`.

**Evidence:**

```text
new(filename: "unset")    → URL "/blur=1/filename=unset/src/x.jpg"
  builder spec filename "unset", parsed spec filename nil
new(cachebuster: "unset") → URL "/blur=1/cb=unset/src/x.jpg"
  builder spec cachebuster "unset", parsed spec cachebuster nil
```

`validate/1` returns `{:ok, []}` for both.

**Suggested fix:** Reject `"unset"` as a `:path_token` in the builder, as `detect` already does on the URL side (`option_spec.ex:721`). The other choice is to let the URL write a literal, but nothing in the grammar can.

---

## 3. The builder accepts the detect class `"unset"`, which the server rejects

**Severity:** Low. `validate/1` and `url/3` pass, even with `:validate_against`, but the URL answers `400`.

**Where:** `image_pipe_url/lib/image_pipe/plan/builder/values.ex:282` (`valid_class?/1` checks only the character pattern). The parser rejects `unset` at `image_pipe_url/lib/image_pipe/api/option_spec.ex:721` (`valid_detect_class?/1`).

**Evidence:**

```text
group(resize: [width: 10, height: 10, fit: :cover], detect: ["unset"])
  validate/1 → {:ok, []}
  url/2      → {:ok, "/w=10/h=10/fit=cover/detect=unset:1/src/x.jpg"}
  parse      → {:error, {:invalid_request, [invalid_detect]}}
```

**Suggested fix:** Add `defp valid_class?("unset"), do: false` next to the `"all"` clause in `values.ex`.

---

## 4. `-0.0` survives in gradient and progressive-blur `start`/`stop`

**Severity:** Low. Equivalent requests get different cache keys and ETags. The pixels are the same. This is what's left of bead `image_plug-e4a.5.5` after `f5b2f222`.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:328` (`assemble_progressive_blur/1`) and `:345` (`assemble_opacity_effect/1`) normalize the angle but not `start` or `stop`. Both the parser (`Value.fraction/1`, `api/value.ex:96`, returns `n * 1.0`) and the builder (`normalize(_, :fraction)`, `values.ex:33`) let `-0.0` through.

**Evidence:**

```text
/gradient=0.5,red,0,-0.0,1/src/x   → gradient.start == -0.0
/gradient=0.5,red,0,0,1/src/x      → gradient.start == 0.0
builder progressive_blur: [sigma: 1.0e-7, start: -0.0, …]
  → builder spec start -0.0, URL writes "0", parsed start 0.0
```

All 14 mismatches in the 22,000-plan fuzz run came from these four fields. Other fractions are already safe. `focus` and `bg` alpha go through `fraction/1` in `spec.ex:369`. Colorize, monochrome and watermark opacity treat `0` as absent.

**Suggested fix:** Map `start` and `stop` through the existing `fraction/1` in both assemble functions. Adding `-0.0` to the round-trip property's fraction generators would catch any fraction missed later.

---

## 5. `pad=0` stays in the Spec as a no-op padding

**Severity:** Low. `pad=0` and no `pad` give the same pixels but different cache keys and ETags. A zero pad also turns off shrink-on-load for placeholder outputs.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:169` (`pad: Map.get(group_map, :padding)`) keeps `{0, 0, 0, 0}`. The neighbouring effects drop their identity values instead: blur `0`, sharpen `0`, brightness `0`, pixelate `1`, contrast `1`. In `image_pipe`, the executor skips the zero pad (`transform/executor.ex:450`), but `pixel_sized_effects?/1` (`executor.ex:938-943`) counts any non-nil `pad`. So `output=blurhash`/`lqip-css` with `pad=0` loses the placeholder decode reduction.

**Evidence:**

```text
/pad=0/src/x → group.pad == {0, 0, 0, 0}; Spec differs from /src/x
builder padding: 0 → same
```

**Suggested fix:** Normalize `{0, 0, 0, 0}` to `nil` in `assemble_group/1`, like the other identity values.

---

## 6. Huge float rotations and trim tolerances differ between `run/4` and the URL

**Severity:** Very low. Only absurd values trigger it, but then a builder plan and its own URL rotate by different angles.

**Where:** `image_pipe_url/lib/image_pipe/api/serialized_value.ex:28` (`decimal/1`) writes a float's shortest representation, so `1.0e300` becomes `1` and 300 zeros. The parser reads that as the exact integer 10^300. That integer isn't the float's value. `Plan.Angle.rotation/1` (`angle.ex:19`) and `integral/1` (`spec.ex:366`) keep the integer exactly, so the remainders differ. This happens for any float of 2^53 or more.

**Evidence:**

```text
group(rotate: 1.0e300) → builder spec rotate nil (0°), URL parses to rotate 280
group(rotate: 1.0e20)  → 280 and 280 (agree)
```

The same holds for `trim: {"red", 1.0e308}`, where the tolerance integer differs.

**Suggested fix:** The simplest fix is to bound the builder's `rotate` to finite values below 2^53, and the trim tolerance too. Plain integers are exact on both sides already. Writing the exact decimal expansion of large floats would also fix it.

---

## 7. `Issue` docs list `:invalid_offset`, which nothing returns now

**Severity:** Low (docs and dead code).

**Where:** `image_pipe_url/lib/image_pipe/plan/spec/issue.ex:51` documents `:invalid_offset` as "a pixel offset is too large to multiply by the group's `dpr`". `5b957192` removed `offset_errors/2` from `Spec.Validation`, so no check produces that issue. The parser clause for it, `semantic_message(%{detail: :invalid_offset})` at `image_pipe_url/lib/image_pipe/api/parser.ex:500`, is dead. Malformed offsets still fail at parse time with the `:invalid_offset` diagnostic, which is a different struct.

**Suggested fix:** Remove the bullet and the parser clause. Per AGENTS.md, load the `writing-docs` skill for the `@moduledoc` edit.

---

## Checked and fine

- The byte scanners match the regexes they replaced: `\A`/`\z` anchoring, a second `.` in decimals, and the empty string.
- After `ea4d0f4c`, option names and URL keys are one-to-one (no duplicates in `OptionSpec.all/0`), so the position map loses nothing.
- Every encoder option field and value round-trips, including `false` values written as `name:false`.
- `ValueSpellings` maps each value to one spelling.
- The value bounds in the builder and the parser agree for `w`, `h`, `min-w`, `min-h`, `pad`, lengths, `dpr`, `zoom`, `blur`, `sharpen`, `pixelate`, `crop-ratio`, detect weights, `wm-scale` and `wm-gap`.
- In `url_with_issues/3`, a rejected key or value can't produce a valid segment. Keys and values are percent-encoded (`/` included), and every option rejects a value starting with `!`.
- `image_url/2` compile-time checks (read, not run): variables, assigns, sigils and interpolated strings become `:unset` or are left out, and literal negatives and tuples are checked.
- Signature canonical spelling, key rotation order, the independence check between signing and encryption keys, and the canonical base64 check on `enc/` tokens.
- `base_url` validation rejects scheme-relative URLs, credentials, query strings, fragments and dot segments.
- `validate_known/4` with stub presets (read, not run) reports no false errors. The override families make cross-layer conflicts impossible. It can miss a warning when request defaults move to a later group, which is minor.

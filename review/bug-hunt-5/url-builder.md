# Bug hunt 5: URL builder

Area: `image_pipe_url`, which covers the option grammar and parser, the builder, presets and request defaults, `Plan.Spec` canonical form, `Plan.validate/4` and `validate_known/4`, URL config, the `image_url/2` helper, signing, and source encryption. The checks ran against `main` at `8edf03b` (0.3.0) on Elixir 1.20.4 / OTP 29. The `image_pipe_url` suite passes (642 tests, 29 properties).

## How this was checked

- **Commits since hunt 4.** I read every `image_pipe_url` commit since `db4fe3c`: the `kernel` option (`8137829`), the `priority` request option (`73c0180`), the preset conflict check (`3f82e42`), exact integers for big floats (`606ee29`), and the hunt 4 fixes.
- **Round trip.** About 17,000 random plans went through builder, URL, `Path.extract/2` and `Parser.parse/2`, compared with `Plan.to_spec/1`. They covered every group, resize, output and request option, `kernel`, `priority`, `:unset`, and edge numbers. Another 3,600 compared the builder's `validate` with the server parse under compiled presets and request defaults, with and without a lookup. 30,000 random URLs went through the parser to look for crashes, and none crashed.
- **End to end.** Findings 1 and 8 were confirmed with `ImagePipe.Plug.call/2` and a file source in `image_pipe`.

## Earlier reports

Every finding in `bug-hunt-4/url-builder.md` is fixed on `main`: preset and default conflicts fail config (`3f82e42`), `"unset"` as filename, cachebuster or detect class (`2e073f1`), `-0.0` bands and `pad=0` (`8f4d8e7`), big floats (`606ee29`), and `:invalid_offset` (`d8470a5`). In beads, epic `image_plug-6lz0.2` holds them, all closed except the server changelog task `6lz0.2.8`. None of the findings below is in beads.

| # | Finding | Severity |
| --- | --- | --- |
| 1 | A huge `trim` tolerance in the URL gives a 500 | Medium |
| 2 | `unset` on one member of an override family clears the whole inherited family | Medium |
| 3 | A group holding only `unset`s is dropped, so its unsets are lost and request defaults move to the next group | Medium |
| 4 | Writing only a modifier (`anchor-offset`, `extend-at`, `extend-offset`) wipes the inherited anchor or canvas | Medium-low |
| 5 | Options in a dropped URL group are credited to group 0 | Low |
| 6 | `validate` and `validate_known` number issue locations differently | Low |
| 7 | `validate_known` stubs drop a group, so request defaults move and warnings are missed | Low |
| 8 | The builder accepts sources the server always rejects | Low |
| 9 | Uniform detect weights split the cache key | Low |
| 10 | A zero region origin in `pct` and in `px` gives different Specs | Low |
| 11 | Presets that aren't a map raise unhelpful errors | Low |
| 12 | Parser error messages don't state the real bounds | Low (messages) |

---

## 1. A huge `trim` tolerance in the URL gives a 500

**Severity:** Medium. Any client can make a request crash with `500 internal server error`. The builder rejects the same value.

**Where:** `image_pipe_url/lib/image_pipe/api/option_spec.ex:1032` (`parse_tolerance/1`) only checks `n >= 0` on `Value.number/1`, which has no size limit, and `Spec.assemble_trim` keeps the integer exactly. The crash is in `image_pipe/lib/image_pipe/transform/executor.ex:924` (`trim_op/2`): `tolerance * 1.0` raises `ArithmeticError` for any integer of about 1.8e308 or more.

**Evidence:**

```text
/trim=fff,1<400 zeros>/src/exif_2.jpg
  → (ArithmeticError) bad argument in arithmetic expression
    lib/image_pipe/transform/executor.ex:924: ImagePipe.Transform.Executor.trim_op/2
  → 500 "internal server error"
builder group(trim: {"fff", 10**400})
  → {:error, {:invalid_request, [%Issue{reason: :invalid_value, …}]}}
```

The builder runs the tolerance through `float/1`, which rescues the overflow. A huge integer in `max-bytes`, `page`, `expires` or `rotate` is handled correctly; only `trim` crashes.

**Suggested fix:** Give the tolerance an upper bound in `ValueBounds` and use it in both `parse_tolerance/1` and the builder. Tolerance is a colour distance, so a few hundred is already "trim everything". That also removes the builder's acceptance of `1.0e300`, which serializes as a 301-digit integer.

---

## 2. `unset` on one member of an override family clears the whole inherited family

**Severity:** Medium. Unsetting an option that no layer set still removes other inherited options. The docs say `unset` "removes a preset's value as if it had never been set" (`image_pipe/docs/requesting-images.md:293`).

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex:344` (`prune_families/3`), called from `merge_group/2` (`:266`) and `merge_request/2`. A family is cleared whenever the next layer holds any key of it, and an `:unset` value counts as one.

**Evidence** (server parse with compiled presets):

| Preset | URL | Result |
| --- | --- | --- |
| `c = "crop=60,40/anchor=top"` | `/preset=c/region=unset` | the crop is gone |
| same `c` | `/preset=c/focus=unset` or `detect=unset` | `guide: {:anchor, :center}`, `anchor=top` lost |
| `q = "q=80"` | `/preset=q/autoquality=unset` | `quality: nil` |
| `wm = "wm=logo"` | `/preset=wm/wm-src64=unset` | `watermark: nil` |
| `e = "w=100/h=100/extend/extend-at=top"` | `/preset=e/extend-at=unset` | the canvas is removed |

**Suggested fix:** Let only non-`:unset` values reset a family. An `:unset` drops its own key, and `prune_unset_dependents/3` already clears what depended on it.

---

## 3. A group holding only `unset`s is dropped, so its unsets are lost and request defaults move to the next group

**Severity:** Medium. `unset` written in the first group stops working as soon as the URL has a second group, and the request defaults silently land in a later group.

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex:194` (the `kept` step in `compose_groups/4`) drops groups that are empty after `drop_unset/1`, before the defaults merge into the first group. Preset compilation drops such groups the same way, so pipeline presets are affected too.

**Evidence:**

```text
request_defaults "w=200":
  /w=unset/blur=2/src/x    → resize nil, blur 2.0        (correct)
  /w=unset/-/blur=2/src/x  → one group, w 200, blur 2.0  (the unset is lost)
defaults "wm=logo", preset nowm = "wm=unset":
  /preset=nowm/-/w=100     → the logo is applied, in the w=100 group
defaults "blur=3", preset p = "blur=unset/-/w=100":
  /preset=p                → blur 3.0
```

The builder agrees with the server here, so this is a semantics bug, not a mismatch.

**Suggested fix:** Decide whether the first group is empty after the defaults merge into it, or keep a group carrying an `:unset` until then.

---

## 4. Writing only a modifier wipes the inherited anchor or canvas

**Severity:** Medium-low. This may be deliberate, but it isn't documented, and the result is a silent change plus an inert warning.

**Where:** The same `prune_families/3`. `@guide_family` (`presets.ex:26`) includes `:anchor_offset`, and `@canvas_family` (`:27`) includes `:extend_at` and `:extend_offset`. Writing any of them clears the preset's `anchor` or `extend`.

**Evidence:**

```text
preset c = "w=100/h=100/fit=cover/anchor=top/anchor-offset=10,10"
  /preset=c/anchor-offset=5,5 → guide {:anchor, :center},
                                ignored [{:group, 0, :anchor_offset}]
preset e = "w=100/h=100/extend/extend-at=top"
  /preset=e/extend-at=bottom  → no canvas, only an inert warning
```

`requesting-images.md:285-289` lists `anchor`, `focus`, `detect`, `region`, `q` and `wm` as replacing a set, not the modifiers.

**Suggested fix:** Let only the principals (`anchor`, `focus`, `detect`, `extend`, `extend_ratio`) reset their family, and merge modifiers like ordinary options.

**Question for Håvard:** Is replacing the anchor when only `anchor-offset` is written intended? If so, the docs should say so, and the warning should say why.

---

## 5. Options in a dropped URL group are credited to group 0

**Severity:** Low. False "ignored" warnings reach `ignored_options` telemetry and `ImagePipe.validate`, real inert warnings go missing, and diagnostic spans point at the wrong segment.

**Where:** `image_pipe_url/lib/image_pipe/api/parser.ex:395`: `Map.get(new_index, occurrence.group_index, 0)`. A dropped group has no entry in `new_index`, so its occurrences move to group 0. `written?` then treats them as written in group 0, and the `invalid` set suppresses group 0's inert checks.

**Evidence:**

```text
preset p = "fit=cover"; /preset=p/blur=2/-/fit=unset/src/x
  server  → ignored [inert_option {:group, 0, :fit}]   (fit came from the preset)
  builder → validate {:ok, []}
/kernel=nearest/-/w=abc/src/x       → only invalid_dimension
/kernel=nearest/-/w=abc/gray/src/x  → invalid_dimension plus the inert kernel warning
```

In the first `kernel` URL, the invalid `w` of the dropped group is charged to group 0 and hides the kernel warning.

**Suggested fix:** Leave out the occurrences of dropped groups, or keep them under a sentinel index, instead of defaulting to 0.

---

## 6. `validate` and `validate_known` number issue locations differently

**Severity:** Low. Issues point at the wrong `group/2` call when an earlier call adds no group, and the `image_url` log lines name the wrong group too.

**Where:** `image_pipe_url/lib/image_pipe/plan.ex:177` (`spec/4`) returns `Spec.resolve` locations numbered after expansion. `validate_known_groups/6` (`:222`) maps them back to the plan's own groups.

**Evidence:** With `fmt = "format=png"`, `group(presets: ["fmt"]) |> group(resize: [fit: :cover]) |> group(presets: ["u"])`:

```text
u known                       → [{:group, 0, :fit}]
preset_lookup, u unknown      → [{:group, 1, :fit}]
```

`fit` was written in the plan's group 1.

**Suggested fix:** Map locations through `expanded.origins` in `spec/4`, as `in_plan_groups/3` already does.

---

## 7. `validate_known` stubs drop a group, so request defaults move and warnings are missed

**Severity:** Low.

**Where:** `image_pipe_url/lib/image_pipe/plan.ex:222-244`. An unknown preset is stubbed with an empty group, so a group naming only that preset is dropped (finding 3's mechanism) and the defaults merge into the next group.

**Evidence:** `validate_against: [request_defaults: "w=100", preset_lookup: true]` with `group(presets: ["u"]) |> group(resize: [fit: :cover])` gives `{:ok, []}`. With `u` known as `"blur=2"`, it gives `{:ok, [inert_option {:group, 1, :fit}]}`, which matches the server.

**Suggested fix:** Make stub groups non-droppable, for example with a placeholder key stripped before resolving. Fixing finding 3 may cover this.

---

## 8. The builder accepts sources the server always rejects

**Severity:** Low. `url/3` returns `{:ok, url}` (with `validate_against` too), and every request to that URL is a `400 invalid source`.

**Where:** `image_pipe_url/lib/image_pipe/api/url.ex:91` (`source/1`) checks only non-empty and valid UTF-8. `image_pipe_url/lib/image_pipe/plan/builder/values.ex:48` (`normalize(_, :source)`) does the same for `watermark_source:` and doesn't normalize it. The server's `Source.Parser.translate/2` (`image_pipe/lib/image_pipe/source/parser.ex:38-47`) normalizes with `Plan.Source.normalize/1` and rejects an empty result and any NUL byte.

**Evidence:**

```text
url(group(blur: 1), "a\0b.jpg")        → {:ok, "/blur=1/src/a%00b.jpg"}  → 400 invalid source
url(group(watermark_source: "/"), …)   → {:ok, "/wm-src64=Lw/src/x.jpg"} → 400 invalid source
url(group(watermark_source: "a\0"), …) → {:ok, "/wm-src64=YQA/src/x.jpg"} → 400 invalid source
```

**Suggested fix:** Share one source check in `image_pipe_url` (normalize, then reject empty and NUL) and use it for the main source and `watermark_source:`. Update the `:invalid_source` line in the `url/3` docs.

---

## 9. Uniform detect weights split the cache key

**Severity:** Low. Same pixels, different cache keys and ETags.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:299` (`assemble_detection/1`) drops only weights equal to the default. `image_pipe/docs/content-aware-gravity.md:59-60` says "a weight shared by every region cancels out of the average", and the weighted centroid is scale-invariant.

**Evidence:**

```text
/detect=face/…            → {:detect, {["face"], %{}}}
/detect=face:3/…          → {:detect, {["face"], %{"face" => 3.0}}}
/detect=all:2/…           → {:detect, {:all, %{default: 2.0}}}
/detect=face:2,car:2/…    → {["car", "face"], %{"car" => 2.0, "face" => 2.0}}
```

**Suggested fix:** Drop the weights of a class list whose weights are all equal, and the default of `:all` when it has no other weights.

---

## 10. A zero region origin in `pct` and in `px` gives different Specs

**Severity:** Low. Same pixels, different cache keys.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:365` (`assemble_lengths/1`). Offsets go through `normalize_zero_length/1`, which maps `{_, 0}` to `{:px, 0}`. Region lengths don't.

**Evidence:**

```text
/region=0,0,10,10       → {{:px, 0}, {:px, 0}, {:px, 10}, {:px, 10}}
/region=0pct,0pct,10,10 → {{:pct, 0}, {:pct, 0}, {:px, 10}, {:px, 10}}
```

**Suggested fix:** Normalize the region's x and y with `normalize_zero_length/1`. Width and height can't be zero.

---

## 11. Presets that aren't a map raise unhelpful errors

**Severity:** Low (config errors).

**Where:** `image_pipe_url/lib/image_pipe/url/config.ex:153` runs `Map.new/2` before any type check, because the schema type is `:any`. `image_pipe/lib/image_pipe/config.ex:541` follows the same pattern (read, not run). The intended "expected a map of preset name…" message in `api/presets.ex:290` can't be reached.

**Evidence:**

```text
ImagePipe.URL.config(validate_against: [presets: "x"])   → Protocol.UndefinedError
ImagePipe.URL.config(validate_against: [presets: nil])   → Protocol.UndefinedError
presets: [{"a", "w=1"}, :bad]                            → FunctionClauseError
```

**Suggested fix:** Check `is_map/1` before `Map.new/2`, or use a `{:map, :string, :any}` schema type.

---

## 12. Parser error messages don't state the real bounds

**Severity:** Low (messages).

**Where:** `image_pipe_url/lib/image_pipe/api/parser.ex`, the `message_for/1` clauses.

**Evidence:**

```text
blur=1001             → "expected a non-negative number"            (max 1000)
sharpen=11            → "expected a non-negative finite number"     (0 or 0.000001..10)
dpr=3000000000        → "expected a positive finite decimal"        (max 2147483647)
zoom=3000000000       → "expected a positive scalar or x,y pair"    (same)
pixelate=3000000000   → "expected a positive integer"               (same)
detect=face:2000000   → "expected unique class[:positive-weight] items" (max 1,000,000)
gradient=0.5,red,,0.5 → "expected opacity,color[,direction,start,stop]"
builder dpr: 0        → "invalid scale_factor value" (internal kind name)
```

The gradient message reads as all-or-nothing, but each trailing field is optional on its own.

**Suggested fix:** State the ranges, and write gradient as `opacity,color[,direction[,start[,stop]]]`. Load the `writing-docs` skill for the wording.

---

## Checked and fine

- `kernel` and `priority`: round trips, `kernel=lanczos3` vs absent, `priority=normal` vs absent, the inert `kernel` warning, and `unset` pruning of an inherited `kernel`. `priority` stays out of the cache key and ETag (`image_pipe/lib/image_pipe/execution/identity.ex`).
- The preset conflict check from `3f82e42`, unknown watermarks, and `request_watermarks: false` raise at config as documented.
- Field-merged `:unset` in `format-q` and the encoder options, `q` pruning `format-q`, and pipeline presets with defaults or request-only presets.
- The `image_url` helper: variables, assigns, module attributes, interpolation, sigils, tuples with variables and negative literals become `:unset` at compile time; runtime `:warn`/`:raise`, a `nil` source and empty groups behave as documented.
- Signing: canonical signature spelling, key rotation, and the `sign_path/2` shape checks. Source encryption: A256CBC-HS512 authenticates before unpadding, the token must be canonical base64, and a watermark under an explicit IV derives its own.
- The 64-segment limit matches `Path`, and a leading `sig=` isn't counted.
- `Path.diagnostic_path/1` masks `sig=`, `wm-enc=` and the `enc/` token before they reach an error body.

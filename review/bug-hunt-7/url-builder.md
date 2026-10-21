# Bug hunt 7: URL builder

Area: `image_pipe_url` (option grammar and parser, builder, presets and request defaults, `Plan.Spec`, `validate`/`validate_known`, URL config, signing, source encryption) plus the parse step of `image_pipe` (`ImagePipe.Plug.Request`, `ImagePipe.Presets` lookup) and the URL parts of `ImagePipe.Config`. Checked against `main` at `6a87579` on Elixir 1.20.4 / OTP 29.

## How this was checked

- **Commits since hunt 6.** I read every commit since `fe70ecc` that touches this area: the hunt 6 fixes (`bdeef68`, `7861e7a`, `b84cd9d`, `accfa70`, `6073d87`), the parse fast path (`72a0ccd`), the one-pass `src` decoding (`69e6358`), and the logged-path cut and source redaction (`1354270`, `f082f24`).
- **Nested presets against listed presets.** About 80,000 random cases compared `/preset=ab/…` with `/preset=a,b/…`, where `ab` is defined as `preset=a/<b's options>`, under random request defaults, with group options, request options and `unset`. They should agree; 23 didn't (findings 1 and 2).
- **Parse fast path.** 6,000 random multi-group URLs (with invalid, unknown and duplicate options mixed in) parsed with request defaults `nil` (fast path) and `""` (full expansion), compared including diagnostics and spans. All agreed.
- **Full-frame identity.** 38,000 random URLs with `crop=100pct,100pct`, `region=0,0,100pct,100pct` or `region=0pct,0pct,100pct,100pct` added to one group, compared with the same URL without it. Every pair that parses gives the same groups and output.
- **Wire checks** through `ImagePipe.Plug.call/2` for looked-up presets with watermark problems (finding 4).
- **Edges.** `src` escape decoding against `URI.decode/1`; `Telemetry.request_path/2` and `source_url/1` with malformed escapes (`URI.decode/1` doesn't raise on them in Elixir 1.18 to 1.20, so no crash); the config-time `wm-enc` decryption under named mounts.

## Earlier reports

All five findings in `bug-hunt-6/url-builder.md` (branch `review/bug-hunt-6-url-builder-nby9mu`) are fixed on `main`:

| Hunt 6 | Fixed by |
| --- | --- |
| 1. A multi-group preset's unset-only group is dropped at compile time | `bdeef68` (kept until defaults apply; such a preset is now a pipeline preset), docs in `6073d87` |
| 2. A preset `wm-enc` token made with another key passes config | `accfa70` (config decrypts each static token, also under a mount's keys) |
| 3. `wm-enc=unset` fails config without encryption keys | `accfa70` (only binary tokens are checked) |
| 4. With a preset lookup, `validate` skips conflicts no preset could fix | `7861e7a` (plan-written `mutually_exclusive_options` are kept). Finding 3 below covers the two error reasons it left out |
| 5. Identity crop, region and focus spellings split the cache key | `b84cd9d` for crop and region. `focus=0.5,0.5` was kept on purpose (it rounds differently from the center anchor) |

None of the findings below is in beads.

| # | Finding | Severity |
| --- | --- | --- |
| 1 | An option a later layer replaces or unsets still strips what it replaced | Medium |
| 2 | Nesting presets gives a different result from listing them | Low |
| 3 | Under a preset lookup, `validate` skips unknown watermarks and disabled watermark sources | Low |
| 4 | A looked-up preset with a broken watermark answers 400 or 404, not 500 | Low |
| 5 | Options that only a full-frame crop or region used are dropped without a report | Low |

---

## 1. An option a later layer replaces or unsets still strips what it replaced

**Severity:** Medium. Different images, cache keys and ETags for requests that the docs say are the same, with no warning. It needs a lower layer (request defaults, or a preset listed earlier) that sets the stripped option.

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex`. Layers merge one at a time, and some merges delete options from the layers below:

- `prune_format_qualities/2` (`:337`): a layer's `q` deletes lower layers' `format-q`.
- `prune_region_dependents/2` (`:407`): a layer's `region` deletes lower layers' `crop-ratio` and `crop-ratio-enlarge`, and the guide family (`anchor`, `focus`, `detect`, `anchor-offset`) unless a cover resize is present at that point.
- `prune_unset_dependents/3` (`:363`): a layer's `unset` deletes inherited options that became inert, judged against the merge so far.

The deletions are final. A higher layer that replaces the `q` or `region`, or unsets it, doesn't bring the deleted options back. `docs/presets.md` ("Clearing inherited values") says `unset` removes a value "as if no layer had set it", and "Precedence within a group" says an option written in the URL overrides the preset.

**Evidence** (server parse with compiled presets; the builder shares the code):

```text
defaults "format-q=avif:50", preset q80 = "q=80"
  /w=10/q=unset            → format_qualities %{avif: 50}
  /preset=q80/q=unset      → format_qualities %{}          (q80's q is unset, yet the defaults' format-q is gone)
  /preset=q80/autoquality  → format_qualities %{}, autoquality true
  /autoquality, defaults "format-q=avif:50/q=70"
                           → format_qualities %{avif: 50}, autoquality true

defaults "crop-ratio=3:2/anchor=top", preset zoom = "region=10,10,50pct,50pct"
  /crop=50pct,50pct                         → crop_ratio {3, 2}, guide anchor top
  /preset=zoom/crop=50pct,50pct             → crop_ratio nil,    guide anchor center
  /preset=zoom/region=unset/crop=50pct,50pct → crop_ratio nil,   guide anchor center

defaults "wm-at=top", presets logo = "wm-src64=bG9nby5wbmc", nowm = "wm-src64=unset"
  /preset=nowm/wm-src64=b3RoZXIucG5n        → watermark at top
  /preset=logo,nowm/wm-src64=b3RoZXIucG5n   → watermark at center
```

With `autoquality`, `format-q` formats are encoded at their fixed quality and skip the search (`ImagePipe.Output.Policy`, `fixed_quality_formats`), so the second case encodes AVIF by search instead of at 50. In the last case, `logo,nowm` should equal `nowm` alone; `logo` briefly made the defaults' `wm-at` useful, and `nowm`'s unset then counted it as made inert by the unset.

**Suggested fix:** Decide these deletions once, against the fully merged group, instead of at each merge step:

- `format-q` entries from layers below the highest layer whose `q` survives the merge are dropped; a `q` that a higher layer unsets or replaces with `autoquality` drops nothing.
- `region`'s deletions apply only when `region` survives the merge (and the cover check uses the final group).
- For `unset` dependents, drop an inherited option when it is inert in the final group but wasn't inert in the merge of the layers without the unsets. This keeps the documented `/preset=card/w=unset` behavior (fit and enlarge go unless `h` uses them).

This means merging an ordered list of layers per request instead of folding pairwise; see finding 2 for the compiled-preset side, which the same change fixes.

**Question for Håvard:** Is "as if no layer had set it" the rule you want for these three (so `/preset=q80/q=unset` keeps the defaults' `format-q`), or should the docs instead say a replaced `q` or `region` still clears what it cleared?

---

## 2. Nesting presets gives a different result from listing them

**Severity:** Low. Turning a list of presets into a recipe (`ab = preset=a,b`), which `docs/presets.md` ("Single-group and pipeline presets") recommends, can change the image of every URL that uses it. It needs a lower layer: request defaults with group options, or a preset listed before the recipe.

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex:95`. A preset compiles by merging its layers without the request defaults or the presets listed before it (`compose(groups, request, compiled, nil)`), and the result is stored as one map. At request time that map is merged as a single layer (`compose_groups/4`, `merge_defaults/3` at `:262`, and `compose_pipeline/5` at `:296` for group 0 of a pipeline preset). The pruning steps from finding 1 are decided per layer, so merging `[D, merge(a, b)]` differs from merging `[D, a, b]`:

- an `unset` anywhere in the recipe makes the recipe's ordinary overrides prune inherited dependents too (`prune_unset_dependents/3` sees the whole recipe as the unsetting layer);
- an option that was inert inside the recipe at compile time counts as already inert, so an unset doesn't remove it;
- a `region` in the recipe is judged with the recipe's own cover resize, not the one in the request.

**Evidence** (each pair should match; first is listed, second nested):

```text
presets top = "anchor=top", zoom = "region=10,10,80pct,80pct", card = "w=400/h=300/fit=cover",
        zoomcard = "preset=zoom,card"
  /preset=top,zoom,card   → guide anchor center
  /preset=top,zoomcard    → guide anchor top

presets ratio = "crop-ratio=3:2", zoom = "region=10,10,80pct,80pct", half = "crop=50pct,50pct",
        zoomhalf = "preset=zoom,half"
  /preset=ratio,zoom,half → crop_ratio nil
  /preset=ratio,zoomhalf  → crop_ratio {3, 2}

defaults "w=300/enlarge", presets nowidth = "w=unset", short = "min-h=60",
        nowidthshort = "preset=nowidth,short"
  /preset=nowidth,short   → enlarge false
  /preset=nowidthshort    → enlarge true

defaults "h=100/kernel=nearest", presets auto_h = "h=auto", nograd = "gradient=unset",
        both = "preset=auto_h,nograd"
  /preset=auto_h,nograd/min-h=60 → kernel nearest
  /preset=both/min-h=60          → kernel lanczos3   (an unrelated unset drops the defaults' kernel)

defaults "wm-at=top", presets logo, nowm as in finding 1, logo_nowm = "preset=logo,nowm"
  /preset=logo,nowm/wm-src64=…   → watermark at center
  /preset=logo_nowm/wm-src64=…   → watermark at top
```

About 1 in 1,700 random nested/listed pairs differed (23 of about 80,000), all through these three mechanisms. Without a lower layer the two forms always agreed.

**Suggested fix:** Compile a preset to its ordered list of layers per group (nested references inlined), not to one merged map, and merge the full list at request time with the request defaults first. Conflict checks at compile time can still run on the merged result. This undoes part of the speed-up in `72a0ccd` (more merges per request), so it's worth measuring.

**Question for Håvard:** Should a recipe behave exactly like listing its ingredients? If not, the docs should say a nested preset is merged on its own first.

---

## 3. Under a preset lookup, `validate` skips unknown watermarks and disabled watermark sources

**Severity:** Low. `url/3` returns `{:ok, url}` for a URL the server always rejects with 400.

**Where:** `image_pipe_url/lib/image_pipe/plan.ex:271` (`in_plan_groups/5`). Since `7861e7a`, a group naming a preset missing from `:presets` still reports `mutually_exclusive_options` between options the plan writes, because a preset is a lower layer and can't remove them. The same holds for `unknown_watermark` and `watermark_source_disabled` on a plan-written `watermark:` or `watermark_source:`: a preset can't change the name or the server's `request_watermarks`, and the plan's watermark principal replaces any watermark the preset sets. Those two reasons are still skipped. The `ImagePipe.Plan.Spec.Issue` docs say `validate/1` returns `:unknown_watermark` when `:validate_against` lists the names.

**Evidence** (`validate_against: [presets: %{"a" => "blur=1"}, preset_lookup: true, watermarks: [:logo], request_watermarks: false]`):

```text
group(presets: ["unknown"], watermark: :nope)          → validate {:ok, []}, url {:ok, "/preset=unknown/wm=nope/src/x.jpg"}
group(presets: ["a"], watermark: :nope)                → {:error, [unknown_watermark at {:group, 0, :watermark}]}
group(presets: ["unknown"], watermark_source: "logo.png")
                                                       → validate {:ok, []}, url {:ok, "/preset=unknown/wm-src64=bG9nby5wbmc/src/x.jpg"}
group(presets: ["a"], watermark_source: "logo.png")    → {:error, [watermark_source_disabled ...]}
```

**Suggested fix:** In `in_plan_groups/5`, also keep `:unknown_watermark` and `:watermark_source_disabled` issues whose locations the plan writes (the same `written?/4` test as `plan_conflict?`), and mention them next to the conflict sentence in the `:preset_lookup` docs (`url/config.ex:71`, `url.ex:423`).

---

## 4. A looked-up preset with a broken watermark answers 400 or 404, not 500

**Severity:** Low (a host's stored-definition mistake is reported as the client's). The 404 is the misleading one: the image exists, and the response reads as a missing source.

**Where:** `image_pipe_url/lib/image_pipe/api/presets.ex:53` (`compile_lookup/2`) checks looked-up presets with watermarks `nil` and no key check, while `ImagePipe.Config` checks static presets for watermark names, `request_watermarks`, and `wm-enc` decryption (`config.ex:608`). The broken definition then fails each request in `Parser.parse/2` (400) or in `ImagePipe.Plug.Request.decrypt_watermark/3` (`request.ex:117`, 404). `ImagePipe.Presets` says "a broken stored definition is `:invalid_definition` (500), the host's fault".

**Evidence** (through `ImagePipe.Plug.call/2`; the same fragment as a static preset fails config):

```text
stored "wm-enc=<token made with another key>"  → 404 "not found"          static: "has a wm-enc token that source_encryption_keys can't decrypt"
stored "wm=nope" (watermarks: logo)            → 400 "unknown watermark"  static: "unknown_watermark at {:group, 0, :watermark}"
stored "wm-src64=…", request_watermarks: false → 400 "request watermark sources are not enabled"
```

`watermark_wire_test.exs:401` pins a 400 for a looked-up `wm-enc` on a mount without keys, and `docs/storing-presets-in-a-database.md:42` documents a 400 for a stored definition above `:max_effort`, so 400 for host errors has precedent.

**Suggested fix:** Pass the mount's watermark facts to `compile_lookup/2` and run the same `wm-enc` decryption check as config, answering `{:preset, :invalid_definition}` (500). If 400 is the intended answer, at least map an undecryptable stored token to 500 or 400 instead of 404, and document the watermark cases next to the `:max_effort` sentence.

**Question for Håvard:** 500 for every host-side definition problem, or keep 400 for these and document them?

---

## 5. Options that only a full-frame crop or region used are dropped without a report

**Severity:** Low. Only the `ignored` report is affected: the `[:image_pipe, :request, :ignored_options]` telemetry and the warnings from `ImagePipe.validate/2` and `ImagePipe.URL.validate/1`.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:82` (`drop_full_frame/3`). It drops the full-frame crop or region, then drops the options that became inert with `drop_inert/5` and throws the dropped list away (`:93`, `_dropped`). `ignored` is documented as "the inert options the request itself wrote, which `settle/5` dropped".

**Evidence:**

```text
/anchor=top                                       → ignored ["anchor"]
/crop=100pct,100pct/anchor=top/anchor-offset=5,5 → ignored []   (anchor and anchor-offset do nothing)
```

**Suggested fix:** Return the second pass's dropped issues from `drop_full_frame/3` and add them to `settle/5`'s warnings (filtered through `explicit?`). Reporting the full-frame crop or region itself as ignored would also be reasonable.

---

## Checked and fine

- **Parse fast path (`72a0ccd`).** A URL without presets, `unset` or request defaults returns the same `Spec`, ignored list and diagnostics (spans included) as full expansion. `merge_defaults/3` picks the same first writing group as before.
- **Full-frame identity (`b84cd9d`).** Adding a full-frame crop or region to any group never changes a parsing request's groups or output; `crop-ratio` keeps the crop; whole-image crops with offsets are clamped to the image in `Crop.resolve_rect/2`, so dropping them can't change pixels.
- **`src` decoding (`69e6358`).** Same results and errors as the old check plus `URI.decode/1`, including a trailing `%`, `%4`, mixed-case hex and decoded invalid UTF-8.
- **Config `wm-enc` checks (`accfa70`).** Every group of every static preset and the request defaults is decrypted, again under a named mount's keys in `put_url_options/2`; `wm-enc=unset` needs no keys.
- **Logged paths (`1354270`, `f082f24`).** The cut matches the lexer's markers; a malformed escape in a query parameter name doesn't raise on any supported Elixir (1.18 to 1.20, where `URI.decode/1` keeps the `%`); a `#` before `?` in a source keeps the "query" in the fragment, which the origin never receives.
- **Pipeline presets with unset-only groups.** Request defaults merge into group 0 and are cleared by its unsets; a group left empty is dropped and `origins` renumber correctly.

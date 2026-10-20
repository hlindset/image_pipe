# Bug hunt 6: URL builder

Area: `image_pipe_url` (option grammar and parser, builder, presets and request defaults, `Plan.Spec`, `validate`/`validate_known`, URL config, the `image_url/2` helper, signing, source encryption) plus the parse step of `image_pipe` (`ImagePipe.Plug.Request`) and the URL parts of `ImagePipe.Config`. Checked against `main` at `fe70ecc` on Elixir 1.20.4 / OTP 29.

## How this was checked

- **Commits since hunt 5.** I read every `image_pipe_url` commit since `8edf03b`: the hunt 5 fixes (`8a97ee1`, `1083f90`, `45fe2a8`, `0d0c270`, `b64a9da`, `e56f05f`, `dc6a92a`, `8589d22`, `74567bb`, `a80d51c`, `f5682ac`) and the lossless WebP quality change (`e905562`).
- **Preset fuzzing.** About 8,000 random URLs over every option, with `unset`, random single-group and pipeline presets and random request defaults, went through `Path.extract/2` and `Parser.parse/2`. Checks: no crash, shuffling options inside a group gives the same result, and adding `X=unset` for an option no layer sets changes nothing (family members excluded, since their `unset` clears the family by design). No crash, no order dependence, no stray unset effect.
- **Builder against server.** About 6,000 random builder plans with `unset`, `presets:` and output options, under random presets and request defaults in `validate_against`, compared `ImagePipe.URL.validate/1` and `Plan.to_spec/4` with the server parse of the generated URL, including the numbering of ignored-option locations. All agreed.
- **Edges.** Underflowing decimals (`0.000…1` with 400 zeros) for every positive option, zero-origin spellings, identity values, preset fragment shapes, compile-time `image_url/2` checks with runtime values, and `ImagePipe.config/1` with `wm-enc` presets (run in `image_pipe`).

## Earlier reports

All 12 findings in `bug-hunt-5/url-builder.md` were filed and closed in beads (`image_plug-4bfn`, `94yu`, `4jgo`, `4bfz`, `m0l4`, `0sev`, `vq5p`, `42xj`, `v7b7`, `upq3`, `w2w0`), and the fixes are on `main`. Two notes:

- Hunt 5 #9 was fixed only for `detect=all:N`; the class-list case was kept on purpose (off-list regions get weight 1).
- Hunt 5 #3 is only partly fixed. Its third example (a preset `blur=unset/-/w=100` with request defaults `blur=3`) still gives `blur 3.0`. That is finding 1 below.

None of the findings below is in beads.

| # | Finding | Severity |
| --- | --- | --- |
| 1 | A multi-group preset's unset-only group is dropped at compile time | Medium |
| 2 | A preset `wm-enc` token made with another key passes config, then every request 404s | Low |
| 3 | A preset with `wm-enc=unset` fails config on a server without encryption keys | Low |
| 4 | With a preset lookup, `validate` skips conflicts no preset could fix | Low |
| 5 | Identity crop, region and focus spellings split the cache key | Low |

---

## 1. A multi-group preset's unset-only group is dropped at compile time

**Severity:** Medium. The preset's `unset` never reaches the request defaults, and the defaults land in the preset's next group. A preset written with `-` also stops being a pipeline preset.

**Where:** `image_pipe_url/lib/image_pipe/plan/presets.ex:92` compiles a preset with `compose(groups, request, compiled, nil)`, so `compose_groups/4` (`:214`) runs without request defaults and its `kept` step (`:234`) drops every group that holds only `unset`s. The `1083f90` fix merges the defaults before that drop, but only at request time; at compile time there are no defaults yet. `compose_pipeline/5` (`:251`) later merges the defaults into whatever group is now 0.

**Evidence** (server parse with compiled presets; the builder agrees):

```text
preset p = "blur=unset/-/w=100", defaults "blur=3"
  /preset=p                → one group: w 100, blur 3.0
  /blur=unset/-/w=100      → one group: w 100            (the same options in the URL work)
compiled p                 → %{groups: %{0 => %{width: 100}}, request: %{}}

preset nowm = "wm-src64=unset/-/blur=1", defaults "wm-src64=bG9nby5wbmc"
  /preset=nowm/-/w=100     → the default watermark is applied, in the blur group

preset p = "blur=unset/-/w=100"
  /preset=p/blur=1         → accepted, as a single-group preset
```

`docs/presets.md:99` says "A preset containing `-` is a pipeline preset", and `:113` says other options added to one fail with 400.

**Suggested fix:** Keep unset-only groups in compiled presets (they carry the `unset`), and drop empty groups only in `compose_pipeline/5` after the defaults merge, renumbering `origins` the same way `compose_groups/4` does.

**Question for Håvard:** Should a preset like `blur=unset/-/w=100` stay a pipeline preset (it has `-`), so `/preset=p/blur=1` answers 400? Keeping the group makes `pipeline?/1` say yes.

---

## 2. A preset `wm-enc` token made with another key passes config, then every request 404s

**Severity:** Low (configuration mistake caught late). The preset is broken on every request, and the 404 doesn't say why.

**Where:** `image_pipe/lib/image_pipe/config.ex:589` (`concealed_watermarks!/2`) only checks that source encryption keys exist. It runs again for a named mount in `put_url_options/2` (`:816`), whose `source_encryption_keys` may differ from the instance's. The token is first decrypted per request in `ImagePipe.Plug.Request.decrypt_watermark/3`, which returns `:invalid_concealed_source` (404 "not found").

**Evidence:**

```text
token = ImagePipe.URL.encrypt_source("logo.png", config(keys: [k3], source_encryption_keys: [k2]))
ImagePipe.config(keys: [k3], source_encryption_keys: [k1], request_watermarks: true,
                 presets: %{"w" => "wm-enc=" <> token})      → ok
Request.parse(signed "/preset=w/src/x.jpg")                  → {:error, :invalid_concealed_source}
```

**Suggested fix:** In `concealed_watermarks!/2`, decrypt each static `wm-enc` with `Security.decrypt_source/2` under the URL options being checked, and raise naming the preset when none decrypts. The same check then covers mounts with their own keys.

---

## 3. A preset with `wm-enc=unset` fails config on a server without encryption keys

**Severity:** Low. A preset that clears a concealed watermark is rejected, though it needs no key.

**Where:** `image_pipe/lib/image_pipe/config.ex:636` (`concealed_watermark?/1`) tests `Map.has_key?(group, :watermark_token)`, and compiled presets keep `:unset` values.

**Evidence:**

```text
ImagePipe.config(presets: %{"n" => "wm-enc=unset"})
  → ArgumentError: preset "n" uses wm-enc, which needs source_encryption_keys
```

`ImagePipe.URL.config(validate_against: [presets: %{"n" => "wm-enc=unset"}, request_watermarks: false])` accepts it, because `Presets.conflicts/2` drops `unset` first.

**Suggested fix:** Match only a binary token: `match?(%{watermark_token: token} when is_binary(token), group)`.

---

## 4. With a preset lookup, `validate` skips conflicts no preset could fix

**Severity:** Low. `url/3` returns `{:ok, url}` for a URL the server always rejects with 400.

**Where:** `image_pipe_url/lib/image_pipe/plan.ex:233` (`validate_known_groups/6`) and `:268` (`in_plan_groups/3`) drop every issue with a `{:request, _}` location, and every issue in a group naming an unknown preset. This matches the `:preset_lookup` docs, but a preset is a lower layer and can't remove options the plan writes, so a conflict between two plan-written options is an error whatever the preset holds.

**Evidence** (`validate_against: [presets: %{"a" => "blur=1"}, preset_lookup: true]`):

```text
group(presets: ["unknown"]) |> output(quality: 80, autoquality: true)
  → validate {:ok, []}, url {:ok, "/preset=unknown/q=80/autoquality/src/x.jpg"}
group(presets: ["a"]) |> output(quality: 80, autoquality: true)
  → {:error, [mutually_exclusive_options [request: :quality, request: :autoquality]]}
group(presets: ["unknown"], anchor: :top, detect: ["face"], crop: {10, 10})
  → {:ok, []}; the server answers 400 "anchor and detect are mutually exclusive"
```

**Suggested fix:** Also keep `:mutually_exclusive_options` issues whose locations the plan writes itself (use `written?/4`), in any group or the request. Requirement issues (`inert_option`, `auto_dimension`) stay skipped, since a preset can supply the missing option.

**Question for Håvard:** Worth it, or is "groups with an unknown preset aren't checked" the simpler contract to keep?

---

## 5. Identity crop, region and focus spellings split the cache key

**Severity:** Low. Same pixels, different cache keys and ETags.

**Where:** `image_pipe_url/lib/image_pipe/plan/spec.ex:153-154` (`assemble_region/1`, `assemble_lengths/1` for `crop`) and `:284` (`assemble_guide/2` for `focus`).

**Evidence:**

```text
/crop=100pct,100pct/…                → crop {{:pct, 100}, {:pct, 100}}, guide {:anchor, :center}
/region=0,0,100pct,100pct/…          → region {{:px, 0}, {:px, 0}, {:pct, 100}, {:pct, 100}}
/w=10/h=10/fit=cover/focus=0.5,0.5/… → guide {:focus, 0.5, 0.5}
/w=10/h=10/fit=cover/…               → guide {:anchor, :center}
```

A full-frame crop or region does nothing, and a centred focus point gives the centred cover crop.

**Suggested fix:** Drop a `crop` of `100pct,100pct` and a `region` of `0,0,100pct,100pct` in assembly, and map `focus` 0.5,0.5 to the center anchor (only without `anchor-offset`, which needs a named anchor). Low priority; only clients that write these spellings are affected.

---

## Checked and fine

- The hunt 5 fixes: unset-only URL groups keep request defaults in the first writing group, family modifiers merge, `region=unset` no longer prunes the guide, location renumbering in `validate`, `validate_known` and the parser, the trim tolerance bound, the shared source check, the lone `detect=all:N` weight, zero pct region origins, and the non-map presets error.
- By design and left alone: `/blur=unset/-/w=100` with defaults `w=200` resizes twice (the defaults stay in the URL's first writing group); a principal's `unset` (`region`, `autoquality`, `wm-src64`) clears its whole family.
- Underflowing decimals parse to `0.0` and are rejected by every positive option; `blur` and offsets treat them as zero.
- Pipeline presets: combining with request-only presets, request options in another group, and request defaults merging into the pipeline's group 0.
- `image_url/2` compile-time checks with variables in `resize:`, `new:`, `output:` and tuples raise no false warnings.
- Signing and source encryption: canonical signature spelling, salted IVs for watermarks under an explicit IV, deterministic IVs, and `diagnostic_path/1` masking.

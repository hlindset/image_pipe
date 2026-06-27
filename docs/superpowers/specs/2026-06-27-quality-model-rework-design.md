# Quality-model rework: host-config default quality, autoquality precedence, and per-metric scale-dependent knobs

**Date:** 2026-06-27
**Issues:** [#389](https://github.com/hlindset/image_pipe/issues/389) (host-config per-format default quality + autoquality URL-arg override precedence), [#390](https://github.com/hlindset/image_pipe/issues/390) (butteraugli's per-metric default bracket shadowed by the base default)
**Status:** Approved design, pre-plan

## Summary

Three coupled changes to ImagePipe's output-quality model, landing in one PR because they touch the same machinery (`request_defaults/1`, the imgproxy schema, `build_quality_metric`, `Plan.Output`, and `Output.Policy`):

1. **Default output quality (#389-a)** — add host-config global + per-format default quality (imgproxy's `IMGPROXY_QUALITY` / `IMGPROXY_FORMAT_QUALITY`), matching imgproxy's default *values*. Today ImagePipe has no host-config default quality: when resolved quality is `:default` the encoder omits the quality option entirely and libvips' own per-format default is used.
2. **Autoquality precedence flip (#389-b)** — when the URL `autoquality:…:min:max` args provide explicit min/max, they win over per-format config bounds. Today per-format config wins over the URL args, which #389 calls backwards.
3. **#390 cleanup + per-metric scale-dependent knobs** — `min`/`max` are a metric-*independent* file-size guardrail, so the dead per-metric `default_min`/`default_max` are deleted (`70/80` base + per-format brackets is the universal guardrail). `target` and `allowed_error` are metric-*scale-dependent*, so their host config becomes per-metric maps; a value configured for one metric never bleeds into another.

best_format × quality/autoquality interaction, per-format URL autoquality syntax, and full PNG `q`-ignore parity are explicitly out of scope (follow-ups).

## Background: the current model (confirmed in code)

### Quality resolution today

- URL `q` sets `Plan.Output.quality` (`:default | {:quality, 1..100}`); URL `fq` merges into `Plan.Output.format_qualities` (`%{format => quality()}`).
- `Output.Policy.effective_quality/2` ([policy.ex:241](../../../lib/image_pipe/output/policy.ex#L241)):
  - `{:quality, n}` (URL `q`) wins for all formats.
  - else `Map.get(format_qualities, format, :default)` (URL `fq`).
- `:default` → encoder omits the quality option ([encoder.ex:470](../../../lib/image_pipe/output/encoder.ex#L470)) → libvips per-format default.
- **There is no host-config default quality** (no `IMGPROXY_QUALITY` / `IMGPROXY_FORMAT_QUALITY` equivalent), so a deployment cannot set a default without putting `q`/`fq` in every URL.

### imgproxy ground truth

`processing/options.go` `Quality(format)` ([imgproxy checkout](file:///Users/hlindset/src/imgproxy/processing/options.go#L264)) resolves in this order:

1. URL/processing-option global `q` if > 0
2. URL/processing-option per-format `fq[format]` if > 0
3. config `FormatQuality[format]` if > 0
4. config `Quality` (global, default **80**)

Config defaults (`processing/config.go:60`): global `Quality: 80`, `FormatQuality: {webp: 79, avif: 63, jxl: 77}`.

**Note the order:** global URL `q` is checked *before* per-format URL `fq`. ImagePipe's `effective_quality/2` already honors "URL `q` beats URL `fq`", so this rework only appends the two config levels below the existing two URL levels.

### Autoquality bracket resolution today

- `build_quality_metric/7` ([options.ex:405](../../../lib/image_pipe/parser/imgproxy/options.ex#L405)) resolves `min_quality`/`max_quality`/`allowed_error` as `URL field ?? config global ?? per-metric default`.
- But `request_defaults/1` ([imgproxy.ex:319](../../../lib/image_pipe/parser/imgproxy.ex#L319)) and the schema ([imgproxy.ex:64](../../../lib/image_pipe/parser/imgproxy.ex#L64)) eagerly fill `autoquality_min_quality: 70`, `autoquality_max_quality: 80`, `autoquality_allowed_error: 1.0`, so the per-metric `default_min`/`default_max`/`default_error` passed by `build_quality_search` are **unreachable**.
- `Output.Policy.resolve_search/2` ([policy.ex:189](../../../lib/image_pipe/output/policy.ex#L189)) resolves each format as `Map.get(s.format_min, format, s.min_quality)`. Because URL min/max land on the base `min_quality`/`max_quality` and `format_min`/`format_max` come **only** from host config, **per-format config wins over the URL base args**.

### The two-axis distinction (the crux)

| Param | Scale | Cross-metric single global? |
|---|---|---|
| `min_quality` / `max_quality` | encoder Q (1–100), format-relative but **metric-independent** | ✅ fine — a file-size guardrail |
| `format_min` / `format_max` | encoder Q per format, **metric-independent** | ✅ fine — per-format guardrail |
| `target` | metric's own scale (ssim2 score 0–100, butteraugli distance 0–25, size bytes) | ❌ incoherent |
| `allowed_error` | symmetric band on the metric's own scale | ❌ incoherent |

`min`/`max` bound the output to a *sensible file size* ("don't chase a perfect metric score into a 2 MB AVIF or a Q3 mush"); they are per-format precisely because Q is format-relative (jpeg 80 ≠ avif 80 ≠ jxl 80 — imgproxy's own `FORMAT_QUALITY` defaults encode this). They are **not** metric tuning, so `70/80` + the per-format brackets are the correct *universal* guardrail across all metrics, including butteraugli. The unreachable `1/100` butteraugli "default" is "no guardrail at all" — undesirable, hence deleted, not resurrected.

`target` and `allowed_error` live on the metric's own scale, so a single cross-metric global is incoherent: a host configures it for ssim2, a URL flips `metric` to butteraugli, and it inherits an ssim2-scale value. `allowed_error` fails **silently** (a `±1.0` butteraugli band is `[0, 2.0]` — accept almost anything; the intended `±0.1` is `[0.9, 1.1]`); `target` fails **loudly** (`target: 78` is rejected for butteraugli's 0–25 range). Both are fixed by making the host config per-metric.

## Detailed design

### A. Default output quality (#389-a)

**imgproxy schema** ([imgproxy.ex](../../../lib/image_pipe/parser/imgproxy.ex)) — two new options:

```elixir
quality: [type: :pos_integer, default: 80],          # 1..100 enforced in validate (see D)
format_quality: [
  type: {:map, :atom, :pos_integer},
  default: %{webp: 79, avif: 63, jpeg_xl: 77}
],
```

`request_defaults/1` passes both through (`Keyword.get(imgproxy_opts, :quality, 80)`, `Keyword.get(imgproxy_opts, :format_quality, %{webp: 79, avif: 63, jpeg_xl: 77})`).

**`Plan.Output`** gains one field:

```elixir
default_quality: :default,   # :default | {:quality, 1..100}
```

`@type default_quality :: quality()`. Default `:default` keeps the product-neutral struct's "no host configured a default" meaning (a non-imgproxy parser that never sets it preserves today's libvips-default behavior).

**Parser resolution** (in `Options.apply_request_defaults/2` / `resolve_metadata_defaults` area, where config defaults are already folded into `output`):

- `output.format_qualities = Map.merge(normalize(config_format_quality), url_fq)` — config ints normalized to `{:quality, n}`, URL `fq` (already `{:quality, n}`) merged **over** config so URL wins within the per-format slot. (This matches imgproxy: URL `fq` beats config `FormatQuality`, and per-format beats global.)
- `output.default_quality = {:quality, config_quality}`.
- `output.quality` (URL `q`) unchanged.

**`Output.Policy`** carries `default_quality` (copied in both `from_output_plan/3` clauses). `effective_quality/2` becomes:

1. `quality == {:quality, n}` → that (all formats — URL `q` wins, unchanged; explicit `q` on PNG still applies).
2. `quality == :default`:
   - `Map.get(format_qualities, format)` → `{:quality, n}` if present.
   - else `default_for(format)`: `:default` for `:png` (PNG stays lossless — the `80` global default must not trigger PNG quantization, a regression vs today's omit), `default_quality` otherwise.

Net resolution order: **URL `q` → (URL `fq` ∪ config `format_quality`) → config global → (`:default` for PNG / libvips)** — equivalent to imgproxy's `Quality(format)`.

**Encoder unchanged:** `output_options/2` ([encoder.ex:467](../../../lib/image_pipe/output/encoder.ex#L467)) already maps `{:quality, n}` → `[suffix:, quality: n]` and `:default` → `[suffix:]`.

**PNG note:** imgproxy computes `Quality(png) = 80` but its PNG save path ignores the numeric quality (lossless). ImagePipe's generic encoder *does* apply a quality if one is present, so the global default is gated off PNG (step 2 above). Explicit URL `q`/`fq` on PNG is left applying as today; full imgproxy PNG `q`-ignore parity is out of scope.

### B. Autoquality precedence flip (#389-b)

Separate the three bracket sources on the `Plan.Output.QualitySearch.{Size,Ssimulacra2,Butteraugli}` structs so per-format resolution (which runs in `resolve_search/2`, after format negotiation) can apply correct precedence:

- `min_quality` / `max_quality` — config **base** (global guardrail, `70`/`80`).
- `url_min_quality` / `url_max_quality` — URL args, **`nil` when the URL omits them** (the signal is already available: `fields[:min_quality]` is absent unless the URL provided it).
- `format_min` / `format_max` — config per-format maps (guardrail).

`build_quality_metric` sets `min_quality`/`max_quality` from the config global only (`Keyword.get(defaults, :autoquality_min_quality, 70)`), and `url_min_quality`/`url_max_quality` from `Keyword.get(fields, :min_quality)` (nil-able).

`Output.Policy.resolve_search/2` per format:

```elixir
min = s.url_min_quality || Map.get(s.format_min, format, s.min_quality)
max = s.url_max_quality || Map.get(s.format_max, format, s.max_quality)
```

→ **URL > config-per-format > config-base**. Applied to all three metrics (Size, Ssimulacra2, Butteraugli, and the `:jpeg_xl` Butteraugli native path) for consistency. The Resolved (`Output.ResolvedQualitySearch.*`) structs keep their existing shape — they carry the *final* resolved `min_quality`/`max_quality`.

**Format-bluntness is the accepted escape-hatch property.** imgproxy's `autoquality:%method:%target:%min:%max:%error` is a single global pair — there is no per-format URL autoquality arg — so a URL override applies to whatever format is negotiated, losing per-format normalization. This is inherent to imgproxy's grammar and is the intended behavior of a deliberate per-request override; per-format URL control would be a non-imgproxy extension (out of scope).

### C. #390 cleanup + per-metric `target` / `allowed_error`

**Delete dead min/max defaults.** `build_quality_search(:ssimulacra2, …)` and `(:butteraugli, …)` stop passing `default_min`/`default_max` (the `70,80` / `1,100` literals). `build_quality_metric` no longer takes them — min/max come from the config global base (always present, `70`/`80`), with `format_min`/`format_max` as the per-format guardrail. `:butteraugli`'s former `1/100` is gone; it now shares the universal `70/80` + per-format brackets.

**Per-metric `target` config.**

```elixir
autoquality_target: [type: {:map, :atom, {:or, [:integer, :float]}}, default: %{}],
```

Resolution (in `resolve_quality_search_target/3`): `url_target ?? Map.get(config_target_map, metric) ?? default_target(metric)`, where `default_target/1` ([options.ex:473](../../../lib/image_pipe/parser/imgproxy/options.ex#L473)) keeps `{ssimulacra2: 78, butteraugli: 1.0}` and `:size` stays required (`{:error, missing_target}` when unconfigured). `validate_target_range/2` still runs post-resolution against the metric's own range.

**Per-metric `allowed_error` config.**

```elixir
autoquality_allowed_error: [type: {:map, :atom, {:custom, __MODULE__, :validate_non_negative_number, []}}, default: %{}],
```

(or an equivalent map-with-non-negative-values custom validator). Resolution (in `build_quality_metric`): `Keyword.get(fields, :allowed_error) ?? Map.get(config_error_map, metric) ?? default_allowed_error(metric)`, where a new `default_allowed_error/1` helper returns `{ssimulacra2: 1.0, butteraugli: 0.1}`. `:size` does not use `allowed_error`.

This makes the per-metric defaults reachable (fixing the silent butteraugli shadow) and removes cross-metric bleed: a config entry under one metric key is never read for another metric.

`build_quality_metric` thus drops all three `default_*` params; metric-specific defaults live in `default_target/1` and `default_allowed_error/1`.

### D. Validation

- `validate_autoquality_brackets!` ([imgproxy.ex:154](../../../lib/image_pipe/parser/imgproxy.ex#L154)) — min/max base+per-format ordering check, **unchanged** (still single global).
- **New, at the config boundary** (`validate_imgproxy_options!`):
  - `quality` ∈ 1..100; each `format_quality` value ∈ 1..100.
  - Each `autoquality_target` map entry validated against its metric's range (size → positive-integer bytes; ssimulacra2 → 0–100; butteraugli → 0–25) — fail-fast instead of deferring to per-request resolution.
  - Each `autoquality_allowed_error` map entry non-negative.
  - Unknown metric keys in either map rejected (only `:size`/`:ssimulacra2`/`:butteraugli` valid; `:size` has no `allowed_error`).

### E. Tests

- **Parser/planner** (`options`, `imgproxy` tests):
  - Quality resolution order: URL `q` > URL `fq` > config `format_quality` > config `quality`; PNG gated off the global default.
  - Autoquality precedence: URL `min/max` beat per-format config; config per-format beats config base; config base when both omitted.
  - Per-metric `target`/`allowed_error`: URL > config-metric-map > built-in; **cross-metric isolation** (config `%{ssimulacra2: …}` does not leak when metric is butteraugli); butteraugli no longer pinned to ssim2's `1.0` tolerance or `70/80`-only bracket.
  - Config-boundary validation: out-of-range per-metric target, negative allowed_error, unknown metric key, invalid `quality`/`format_quality`.
- **Policy:** `effective_quality/2` (incl. PNG gate, config global covering jpeg); `resolve_search/2` precedence across formats.
- **Wire-level** (`imgproxy_wire_conformance` style): decode-pixel checks where the new default quality observably changes output (e.g. avif default Q63 vs prior libvips default); explicit-format/explicit-`q` bypass; representative autoquality min/max override.
- Delete any now-obsolete tests pinning the old single-global `autoquality_target`/`autoquality_allowed_error` scalar shape or the unreachable `1/100` butteraugli default.

### F. Docs & fiddle

- `docs/imgproxy_support_matrix.md`:
  - **Surface axis** — new `quality` / `format_quality` config options; per-metric `autoquality_target` / `autoquality_allowed_error` maps; the autoquality URL-args-win precedence rule.
  - **Behavioral/pixel axis** — default output quality now matches imgproxy's values (global 80; webp 79 / avif 63 / jxl 77).
- If wire/differential fixtures shift, follow the differential README bake → diagnose → tolerance → quarantine workflow; re-bake only via `mise run diff:bake`; check `SourceInventory` if any source changes (none expected).
- **Compat reviewer required** (behavioral/pixel + surface axes change). At least one reviewer verifies the default-quality values and resolution order against the imgproxy checkout; autoquality precedence is a design choice (Pro feature, not in OSS) — verify against the Pro binary if available, else document as a reasoned choice.
- **Fiddle:** unchanged — these are host-config knobs, not URL options.

## Blast radius & risks

- **Default output bytes change** for jpeg/webp/avif/jxl on every request that omits `q`/`fq`. This is the largest behavioral change; it *improves* imgproxy parity but will shift wire-conformance and likely differential fixtures. Plan to re-bake/re-tune.
- **Cache key / ETag:** `effective_quality` now folds config defaults into the canonical plan; keys/ETags stay deterministic. Greenfield — reshape canonical key data and tests in place, no data-version bump (per cache guidelines).
- **Config-surface break (greenfield, acceptable):** `autoquality_target` and `autoquality_allowed_error` change from scalar to metric-keyed map. A host setting `autoquality_target: 78` must move to `autoquality_target: %{ssimulacra2: 78}`.

## Out of scope (follow-up issues)

- best_format × quality/autoquality interaction (imgproxy "best format may change your quality and autoquality settings").
- Per-format URL autoquality min/max syntax (non-imgproxy extension).
- Full PNG `q`-ignore parity with imgproxy.

## Decisions log

- **#390 → cleanup fork** for min/max (delete dead `1/100`; `70/80` + per-format brackets is the universal metric-independent guardrail), because min/max is a file-size guardrail, not metric tuning.
- **#389-a → match imgproxy default values** (not just add config surface), for drop-in parity.
- **#389-b → URL-wins precedence flip**, accepting the single URL pair's format-bluntness as an inherent escape-hatch property.
- **Scale-dependent knobs (`target`, `allowed_error`) → per-metric host config**, applied to both, removing cross-metric incoherence. `allowed_error`'s silent butteraugli shadow is fixed as a sibling of #390.
- **best_format interaction → deferred.**

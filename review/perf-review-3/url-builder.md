# Performance review 3: URL builder, parsing and signing

Scope: everything in `image_pipe_url/`. That covers URL generation (`ImagePipe.URL`, `ImagePipe.URL.Helpers`, `Plan.Builder.*`, `API.Serializer`, `API.URL`), request-side lexing and parsing (`API.Path`, `API.Parser`, `API.OptionSpec`, `API.Value`, `Plan.Spec*`), signing and source encryption (`Security.*`), and configuration (`URL.Config`, `API.Presets`). Reviewed at `main` 259fb05. No code was changed. Paths are relative to `image_pipe_url/lib/image_pipe/` unless they start with `image_pipe/` or `image_pipe_url/`.

## How this was measured

- Elixir 1.20.4, OTP 29 (JIT), 4 shared vCPUs, `MIX_ENV=dev`, compiled code.
- Microbenchmarks: a compiled loop module calling the real public functions, best of 3 runs of 2,000–200,000 iterations, in µs per call. The machine is noisy, so expect about ±10%.
- Profiles: `tprof` call counts and time, to find hot spots.
- What-if patches: two candidate fixes were patched in temporarily, measured, then reverted. Their numbers bound what a real fix can win.

Baseline numbers:

| Operation | Cost |
| --- | --- |
| Request side: `split_signature` + `verify` + `extract` + `parse` for `/sig=…/w=400/h=300/fit=cover/anchor=smart/sharpen=0.5/-/blur=2/format=webp/q=82/src/https%3A…` | about 50 µs (verify 3.4, extract 9, parse 37) |
| `Parser.parse` by shape | 6.7 µs empty, about +3 µs per option, about +8 µs per extra group |
| Builder side: `new |> group |> group |> output |> url!` for the same plan, signed | 47 µs |
| `image_url/2` call through `ImagePipe.URL.Helpers.__url__/5`, cached config | 29 µs |

The request side is already known to be small next to a warm hit, which perf review 2 measured at 1.3–1.6 ms CPU. So the findings that matter most are on the builder side, which has never been reviewed. It runs once per `image_url/2` call, so a page with 100 images pays for it 100 times.

## Findings, ranked by payoff against risk

### 1. The documented `config:` helper setup rebuilds the URL configuration for every image URL

- **Severity:** Medium. Measured.
- **Where:** `url/helpers.ex:318-323` (`__url__/5` calls `apply(module, function, args)` on every URL). The moduledoc example at `url/helpers.ex:19-31` builds the configuration inside that function (`def config, do: ImagePipe.URL.config(...)`). `image_pipe/docs/shared-url-settings.md:158-167` adds `validate_against:` with presets to the same configuration. The cost is in `url/config.ex:95-125` (`Config.new!`): NimbleOptions validation, hex-decoding the keys, HKDF key derivation for source encryption (`security/source_encryption.ex:28-36,119-124`), and `Presets.compile` for `validate_against`, which parses every preset fragment (`url/config.ex:132-149`).
- **Evidence:** per `image_url/2` call, with the same plan (`resize` + `format: :webp`):

  | Configuration the MFA returns | Built per call | Cached | Overhead |
  | --- | --- | --- | --- |
  | `base_url` + `keys` (moduledoc example) | 39.5 µs | 28.6 µs | +38% |
  | + `encrypt_source` and `source_encryption_keys` | 70.3 µs | about 30 µs | about 2.3× |
  | + `validate_against`, 3 presets and `request_defaults` | 99 µs | 29 µs | 3.4× |
  | + `validate_against`, 20 presets | 401 µs | 29 µs | 14× |

  With 20 presets, a page with 100 images spends about 40 ms of render time rebuilding the same configuration. The `instance:` route doesn't have this problem: it reads the configuration from `:persistent_term` (`image_pipe/lib/image_pipe/config.ex:316-334`).
- **Suggested fix:** don't rebuild per URL. Either:
  - Change the docs so the MFA returns a configuration built once, for example at application start and stored in `:persistent_term` or the app env. The moduledoc says the configuration is "read each time a URL is built, so signing keys stay out of the compiled code", and that still holds for a cached runtime value.
  - Or have the helper cache the MFA result itself, keyed by the MFA, in `:persistent_term`, with a documented way to refresh it after key rotation.

### 2. The builder validates each option against a schema that NimbleOptions re-validates on every call

- **Severity:** Medium. Measured, with a what-if patch.
- **Where:** `plan/builder/options.ex:157`, `NimbleOptions.validate([{key, value}], [{key, spec}])`, once per option in every `new/2`, `group/2` and `output/2` call. Passing a keyword schema makes NimbleOptions run `new!/1` first, which checks the schema against its own meta-schema (`image_pipe_url/deps/nimble_options/lib/nimble_options.ex:345-347`). The schemas themselves are rebuilt on every call: `transform_schema/0` (40 entries) is built twice per `group/2`, once for `group_schema/0` and once for `Keyword.keys(transform_schema())` at line 96.
- **Evidence:**
  - `NimbleOptions.validate/2` for one option: 1.78 µs with a keyword schema, against 0.30 µs with a schema built once with `NimbleOptions.new!/1`. The cost is the same for `:custom` types.
  - `tprof` of the full builder chain: `Keyword.keys/1` runs over about 400 elements per URL, and NimbleOptions' schema-validation functions are the top entries.
  - What-if (compiled schema per key, memoized): `group(resize: [width:, height:, fit:], anchor:, sharpen:)` went from 16.9 to 7.4 µs, and `output(format:, quality:)` from 5.0 to 1.8 µs. That is roughly 13 µs, or 30%, of the 47 µs builder chain.
- **Suggested fix:** compile each option's schema once at compile time, as a module attribute map from key to `NimbleOptions.new!([{key, spec}])`, for the request, group, resize and output schemas. Make `transform_schema/0`'s keys a module attribute too. `Options.validate/2` (line 304) has the same keyword-schema call. Check its callers before changing it.

### 3. Module-attribute regexes are re-imported on every match

- **Severity:** Low. Measured.
- **Where:** `api/option_spec.ex:90-97` (8 patterns used by the value parsers), `api/value.ex:12-14`, `plan/builder/values.ex:18,36,178,297`, `plan/source.ex:10`, `url/config.ex:186`.
- **Evidence:** on OTP 28 and later, a regex stored in a module attribute or a `~r` literal is re-imported with `:re.import/1` on each use. `tprof` shows one `re:import` per `re:run`.
  - `Regex.match?/2` with an attribute regex: 1.60 µs. With a regex compiled at runtime: 0.63 µs. With an equivalent binary pattern match: 0.03 µs.
  - A typical parse runs about 5 regex matches, about 8 µs of the 37 µs parse. Each builder `filename:`, `cachebuster:`, preset or watermark name runs one more (`Values.cast(_, :path_token)` is 1.4 µs).
  - Perf review 2 reported the same pattern in `image_pipe`'s request path, about 21 imports per warm hit, but no bead was filed for it. This finding is the `image_pipe_url` half.
- **Suggested fix:** replace the simple character-class patterns (`\A[A-Za-z0-9._-]+\z`, `\A[0-9]+\z`, `\A-?[0-9]+(\.[0-9]+)?\z`, and the others) with small binary-matching functions or `:binary` scans. They are all anchored single character classes, so that is straightforward.

### 4. The serializer scans all 70 option specs for every group and for the request options

- **Severity:** Low. Measured.
- **Where:** `api/serializer.ex:78-82` (`entries/1`: `for spec <- @options, {:ok, value} <- [Map.fetch(options, spec.name)]`), called once per group and once for the request options.
- **Evidence:** one scan costs 2.45 µs, whatever the map holds. `Serializer.segments/1` is 11.2 µs of the 17.7 µs `url!/3` on the two-group example, and 4.8 µs for a plan with only `w=400`.
- **Suggested fix:** iterate the map instead, and sort its entries by a compile-time `name => position` map built from `OptionSpec.all/0`, so the cost follows the options actually set. Look up `url_key/1`'s spec (line 43) in the same map instead of `Enum.find`.

### 5. `OptionSpec.fetch/1` is a linear search over 70 specs

- **Severity:** Low. Measured. Already listed as a minor item in perf review 2, not filed.
- **Where:** `api/option_spec.ex:688-690`, called once per option segment in `api/parser.ex:187`.
- **Evidence:** 0.2 µs for `w` (index 5), 0.81 µs for `format` (index 51), 1.07 µs for an unknown key, against 0.06 µs for a map lookup. What-if with a map: parse of `/format=webp/q=82/…` went from 14.6 to 11.1 µs, and a 5-option, 2-group path from 36.9 to 35.2 µs.
- **Suggested fix:** a compile-time map from key to spec. `@intent_keys` in `api/parser.ex:27` already shows the pattern.

### 6. Worst-case parse of a 64-segment path is about 370 µs and grows with groups × options

- **Severity:** Low (informational). Measured.
- **Where:** `api/parser.ex:258-276` (`collect_duplicate_errors/2` filters every occurrence once per group) and `api/parser.ex:293-318` (`build_clean_group_maps/2`, the same shape). `api/path.ex:214,226` appends to the segment and error lists with `++`, which is quadratic but bounded at 64.
- **Evidence:** 367 µs for 64 segments in 32 groups, 284 µs for 64 duplicate `blur` options, 203 µs for 64 unknown options. The lexer caps the input at 64 option segments (`api/path.ex:27`), so the cost is bounded. With signing keys configured, parsing runs only after the signature checks out, so only unsigned mounts expose it to arbitrary clients. Even then it is about a quarter of one warm hit and happens before any source fetch.
- **Suggested fix:** none needed now. If it is ever touched, group occurrences by `group_index` once with `Enum.group_by/2` and build the segment list in reverse.

## Checked and found fine

- **Signature verification** (`security/signature.ex`): 3.4 µs, one HMAC-SHA256 per configured key until one matches, plus a base64 round trip. Signing is 2.3 µs.
- **Source encryption** (`security/source_encryption.ex`, `cbc.ex`): `decrypt` 6.7 µs, and encryption adds about 8 µs to `url!/3`. HKDF keys are derived once per configuration. Finding 1 is the case where that happens per URL.
- **Lexing** (`api/path.ex`): 9 µs for a 10-segment path. The time is spread across small binary operations, with no hot spot.
- **Preset-name pass** (`image_pipe/lib/image_pipe/plug/request.ex:47-55`): the double option pass from perf review 1 is fixed. `Parser.preset_names/1` (9 µs) now runs only with `:preset_lookup`.
- **`validate_against` at build time:** `url!/3` with a 20-preset `validate_against` is 37 µs, against 35 µs without it. The checks cost little once the configuration is built.
- **Format detection** (`format/detector.ex`): byte-prefix matching over a bounded header peek, on the cold path only.
- **`Plan.Source.normalize/1`**: 0.03 µs.

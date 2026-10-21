# Docs accuracy pass 1

Docs-vs-code accuracy pass over `hlindset/image_pipe` at `main` `6a87579` (after #1056). Covered: the READMEs, every guide under `image_pipe/docs/` and `image_pipe_server/docs/`, the architecture docs, the public `@moduledoc`/`@doc`/`@spec`/option docs of the three libraries and the server, the HexDocs config in each `mix.exs`, and every relative link and anchor. Report only: no doc edits, no beads.

Most findings were confirmed by running code with the Elixir toolchain: example URLs through the parser (98 in the option reference), builder examples (73), config examples through `ImagePipe.config/1` and `ImagePipeServer.Config.load!/2`, small Plug requests, and `mix docs` builds checked for broken anchors. Findings say when they rest on a runtime check. Duplicates found by more than one area are merged.

**What already matches.** The drift from #1019 and the later cache PRs (#1020, #1049, #1056) is already fixed in the docs: records in memory, `entries` counting, the metadata memo, admission timeouts, owner-file timings and the `cache_stats` fields all match the code. The generated server reference tables are test-enforced, so key names, types and schema defaults in them can't drift.

60 findings: 1 high, 12 medium, 47 low.

| # | Finding | Severity | Area |
| --- | --- | --- | --- |
| 1 | The `image_pipe_url` README example passes `presets:` to `new/2`, which raises | High | URL builder, presets, signing, and the Elixir API |
| 2 | `ImagePipe.run/4` and `child_spec/1` leave out `max_remembered_originals`, which also needs an instance | Medium | URL builder, presets, signing, and the Elixir API |
| 9 | The configuration reference doesn't say which settings are required | Medium | Standalone server |
| 14 | "Without Docker" leaves out the Rust toolchain the build needs | Medium | Standalone server |
| 17 | `X-ImagePipe-Cache-Key` is sent when no cache is configured | Medium | Caching, freshness, delivery, errors, and debug headers |
| 18 | The cache key and ETag lists leave out host output settings and watermark images | Medium | Caching, freshness, delivery, errors, and debug headers |
| 27 | `kernel` is said not to apply to the result-limit scale-down, but it does | Medium | URL option reference and processing semantics |
| 28 | "Requesting images" says an option with no effect fails with `400`, but it is ignored | Medium | URL option reference and processing semantics |
| 33 | `run/4` claims a source content-type policy that doesn't exist | Medium | Getting started, configuration, Plug mounting, and sources |
| 34 | File sources answer 404 for absolute symlinks, even ones that point inside the root | Medium | Getting started, configuration, Plug mounting, and sources |
| 41 | The custom-detector check shows a log line the default Logger doesn't write | Medium | Telemetry, tracing, detection, and SVG |
| 42 | `ImagePipe.Error.tag/1` doesn't exist, and `:error` differs between the request and its stages | Medium | Telemetry, tracing, detection, and SVG |
| 51 | Transform docs describe an `ImagePipe.Transform` behaviour and `Transform.run/3` that no longer exist | Medium | Links, typespecs, HexDocs config, and architecture docs |
| 3 | `presets.md` says an inherited-option example "still fails", but inert options are ignored | Low | URL builder, presets, signing, and the Elixir API |
| 4 | The `image_pipe_url` README lists `mime` as a runtime dependency | Low | URL builder, presets, signing, and the Elixir API |
| 5 | The `ImagePipe.URL.validate/1` example shows a warning that appears only with `:validate_against` | Low | URL builder, presets, signing, and the Elixir API |
| 6 | `ImagePipe.URL` says options with several URL values take a keyword list | Low | URL builder, presets, signing, and the Elixir API |
| 7 | The `:validate_against` doc names `watermark_token`, which isn't a builder option | Low | URL builder, presets, signing, and the Elixir API |
| 8 | The encoder options moduledocs refer to an imgproxy parser that doesn't exist | Low | URL builder, presets, signing, and the Elixir API |
| 10 | A low-priority request turned away by a full pool logs at `info`, not `error` | Low | Standalone server |
| 11 | Deployment says `auth_token` exempts only the health checks | Low | Standalone server |
| 12 | `/stats` doesn't answer `503` for the whole startup and shutdown | Low | Standalone server |
| 13 | Some boot errors don't name the setting or start with `invalid configuration:` | Low | Standalone server |
| 15 | `copy = "keep"` points at a "`[cache] input` pool" and doesn't say it needs one | Low | Standalone server |
| 16 | Server moduledocs leave out settings and the `401` before the `404` | Low | Standalone server |
| 19 | A stopped request isn't killed after one second when a processing pool runs | Low | Caching, freshness, delivery, errors, and debug headers |
| 20 | Not every request waiting for the same original gets a `504` | Low | Caching, freshness, delivery, errors, and debug headers |
| 21 | Lowering the result size limits doesn't replace cached images or change `ETag`s | Low | Caching, freshness, delivery, errors, and debug headers |
| 22 | The `root` option says Plug initialization fails for overlapping roots | Low | Caching, freshness, delivery, errors, and debug headers |
| 23 | The `pool` cache option can't be set the way its doc says | Low | Caching, freshness, delivery, errors, and debug headers |
| 24 | `errors.md` omits the fixed-body `400` responses | Low | Caching, freshness, delivery, errors, and debug headers |
| 25 | The leftover cleanup keeps metadata files it can't read | Low | Caching, freshness, delivery, errors, and debug headers |
| 26 | The memory guide leaves out the instance's long-lived memory | Low | Caching, freshness, delivery, errors, and debug headers |
| 29 | The option index leaves out `priority` | Low | URL option reference and processing semantics |
| 30 | The 64-segment limit also counts `-` separators | Low | URL option reference and processing semantics |
| 31 | The `dpr` reference omits the watermark sizes it multiplies | Low | URL option reference and processing semantics |
| 32 | An unknown `detect` class is accepted when the server has no detector | Low | URL option reference and processing semantics |
| 35 | `fetch/3` docs promise transport timeouts in the runtime options, and leave out what adapters actually get | Low | Getting started, configuration, Plug mounting, and sources |
| 36 | `ImagePipe.Source.Path` suggests adapters see the custom scheme | Low | Getting started, configuration, Plug mounting, and sources |
| 37 | `sources.md` says every adapter takes the cache settings, but S3 takes them per bucket | Low | Getting started, configuration, Plug mounting, and sources |
| 38 | `sources.md` doesn't list the duplicate `root_id` configuration error | Low | Getting started, configuration, Plug mounting, and sources |
| 39 | Redirects to another host keep custom auth headers, which the HTTP guide doesn't mention | Low | Getting started, configuration, Plug mounting, and sources |
| 40 | The documentation overview leaves out two guides | Low | Getting started, configuration, Plug mounting, and sources |
| 43 | SVG watermark parsing isn't in `[:source, :svg_render]`, and SVG limits don't set `:limit` on `[:source, :fetch_decode]` | Low | Telemetry, tracing, detection, and SVG |
| 44 | `:materialize_error` isn't always a `415` | Low | Telemetry, tracing, detection, and SVG |
| 45 | `[:cache, :stage]` never carries `output_format: nil` | Low | Telemetry, tracing, detection, and SVG |
| 46 | `[:debug, :collect, :error]` always has `error: :error` | Low | Telemetry, tracing, detection, and SVG |
| 47 | The blend event's face point isn't area-weighted | Low | Telemetry, tracing, detection, and SVG |
| 48 | Default Logger lines that appear only with `stages: true` are described as always logged | Low | Telemetry, tracing, detection, and SVG |
| 49 | The summary's `:reason` is missing on some failures | Low | Telemetry, tracing, detection, and SVG |
| 50 | Architecture docs link to `image_pipe/docs/api_contract.md`, which doesn't exist | Low | Links, typespecs, HexDocs config, and architecture docs |
| 52 | `Executor.decode_request/2` is now `Executor.decode_options/3`, and arbitrary rotations no longer disable shrink-on-load | Low | Links, typespecs, HexDocs config, and architecture docs |
| 53 | Architecture index names `Output.RequestPolicy` and a "trace Capture" that don't exist | Low | Links, typespecs, HexDocs config, and architecture docs |
| 54 | Rotation range and orientation flushes in the transform doc are out of date | Low | Links, typespecs, HexDocs config, and architecture docs |
| 55 | `ImagePipe.PresetLookup` isn't in any HexDocs module group | Low | Links, typespecs, HexDocs config, and architecture docs |
| 56 | `S3 credentials` anchor in the server configuration reference is broken on HexDocs | Low | Links, typespecs, HexDocs config, and architecture docs |
| 57 | Public `Source.Response` docs point adapter authors at internal functions | Low | Links, typespecs, HexDocs config, and architecture docs |
| 58 | Development page omits the SVG and audit checks | Low | Links, typespecs, HexDocs config, and architecture docs |
| 59 | Root README leaves out `image_pipe_svg/` and promises design plans | Low | Links, typespecs, HexDocs config, and architecture docs |
| 60 | API contract calls `detector` and `detector_required` mount options | Low | Links, typespecs, HexDocs config, and architecture docs |

---

## URL builder, presets, signing, and the Elixir API

How this was checked: docs-vs-code review at commit 6a87579 of `image_pipe_url/README.md`, `image_pipe/docs/{building-server-urls,shared-url-settings,signing-urls,presets,defining-presets,storing-presets-in-a-database,elixir-api,processing-in-elixir,fetching-from-the-server,combined-usage}.md`, and the `@moduledoc`/`@doc`/`@spec`/NimbleOptions docs of `ImagePipe.URL`, `ImagePipe.URL.Config`, `ImagePipe.URL.Helpers`, `ImagePipe.Security` (options schema), `ImagePipe.Plan`, `ImagePipe.Plan.Source`, `ImagePipe.Plan.Spec.Issue`, `ImagePipe.Plan.Output.*Options`, `ImagePipe`, `ImagePipe.Result`, `ImagePipe.PresetLookup`, and the internals they describe (`ImagePipe.API.{URL,Path,Serializer,Presets}`, `ImagePipe.Plan.{Presets,Builder.*,Spec,Spec.Validation}`, `ImagePipe.Security.*`, `ImagePipe.Run`, `ImagePipe.Presets`, `ImagePipe.Processing`, `ImagePipe.Config`). Example URLs were worked out from the serializer and then confirmed by running the builder (`mix run --no-start`) and `ImagePipe.run/4` / `ImagePipe.validate/2` against a synthetic 4000×2667 JPEG. Confirmed correct, among others: the `ImagePipe.URL` moduledoc URL (option order, `%2F` escaping, `sig=` placement), the `group/2`, `output/2`, `url_with_issues/3` and `image_url/2` example URLs, the `url!/3` error message, signature size and key rules (HMAC-SHA256, 43-char base64url, keys of at least 32 bytes hex, first key signs, any verifies), source encryption (32-byte hex keys, A256CBC-HS512, deterministic/random/explicit IV, salted IVs for watermark sources), the 403/400/404/410 bodies in `shared-url-settings.md` and `signing-urls.md`, the pipeline-preset error table in `presets.md`, the preset lookup status table, and every result shown in `processing-in-elixir.md` (dimensions, `{:source, :enoent}`, `{:destination, :enoent}`, the `fit: :fill` issue, `#ImagePipe.Config<instance: nil, ...>`).

### 1. The `image_pipe_url` README example passes `presets:` to `new/2`, which raises


**Severity:** High. The only code example on the package's landing page raises `ArgumentError` when copied.

**Doc:** `image_pipe_url/README.md:31`
**Code:** `image_pipe_url/lib/image_pipe/plan/builder/options.ex:20-90` (request schema has no `presets`), `image_pipe_url/lib/image_pipe/plan/builder/options.ex:272-277` (`presets:` is a group option)

**Evidence:** The README builds `ImagePipe.URL.new(url_config, presets: ["card"]) |> ImagePipe.URL.output(format: :webp) |> ImagePipe.URL.url!("photos/beach.jpg")`. `new/2` takes only the request controls (`orient`, `page`, `filename`, `attachment`, `cachebuster`, `priority`, `expires`, `debug`); `presets:` exists only in `group/2`. Running the snippet, `url/3` returns `{:error, {:invalid_request, [%Issue{reason: :unknown_option, locations: [request: :presets]}]}}`, so `url!/3` raises `ArgumentError` "cannot build URL: unknown_option at {:request, :presets}".

**Suggested wording:**

```elixir
url =
  ImagePipe.URL.new(url_config)
  |> ImagePipe.URL.group(presets: ["card"])
  |> ImagePipe.URL.output(format: :webp)
  |> ImagePipe.URL.url!("photos/beach.jpg")
```


### 2. `ImagePipe.run/4` and `child_spec/1` leave out `max_remembered_originals`, which also needs an instance


**Severity:** Medium. Following the docs, a caller who passes `max_remembered_originals` to `config/1` or as a `run/4` option gets an `ArgumentError` the docs don't mention.

**Doc:** `image_pipe/lib/image_pipe.ex:115-119`, `image_pipe/lib/image_pipe.ex:228-232`
**Code:** `image_pipe/lib/image_pipe/config.ex:710-718`, `image_pipe/lib/image_pipe/config.ex:793-803`

**Evidence:** `child_spec/1` says "A configuration with `cache` or `input_cache` must be used through an instance ... `run/4` with a configuration from `config/1` raise `ArgumentError` for a configuration with a cache." `run/4` says "An instance name takes the same options, except `:cache` and `:input_cache`, which raise `ArgumentError`." Since PR #1019 (commit 0784b6b added `max_remembered_originals`), `reject_caches_without_instance!/1` also raises for a configuration whose raw options contain `:max_remembered_originals`, and `override_all/2` lists `@instance_keys [:cache, :input_cache, :max_remembered_originals]`. Confirmed at runtime: `ImagePipe.run(ImagePipe.config(max_remembered_originals: 10), ...)` raises "a configuration with cache, input_cache or max_remembered_originals must be used through an ImagePipe instance ...", and `ImagePipe.run(MyInstance, ..., max_remembered_originals: 5)` raises "cache, input_cache and max_remembered_originals belong to the instance ...".

**Suggested wording:** In `child_spec/1`: "A configuration with `cache`, `input_cache`, or `max_remembered_originals` must be used through an instance, which starts the processes and the table they need. An `ImagePipe.Plug` mount without `:instance`, and `run/4` with a configuration from `config/1`, raise `ArgumentError` for such a configuration." In `run/4`: "An instance name takes the same options, except `:cache`, `:input_cache`, and `:max_remembered_originals`, which raise `ArgumentError`: they belong to the instance."

**Also:** the `ImagePipe.Plug` moduledoc (`image_pipe/lib/image_pipe/plug.ex:16-21`) has the same gap: `init/1` raises for `:max_remembered_originals` too (`ImagePipe.Plug.init(max_remembered_originals: 10, sources: [])` raises the instance error). Suggested: "so `init/1` raises `ArgumentError` for a configuration with `:cache`, `:input_cache`, or `:max_remembered_originals`."


### 3. `presets.md` says an inherited-option example "still fails", but inert options are ignored


**Severity:** Low. A reader expects a `400` that the server never sends, and the example given does resize.

**Doc:** `image_pipe/docs/presets.md:62-64`
**Code:** `image_pipe_url/lib/image_pipe/plan/spec/validation.ex:251-252`, `image_pipe_url/lib/image_pipe/plan/spec.ex:55-70`

**Evidence:** "Options written in the same URL are kept, so `/preset=card/w=unset/fit=cover` still fails when nothing else resizes." An option without its prerequisite is an `:inert_option` with severity `:warning`; `settle/5` drops it and the request succeeds (`requesting-images.md:348` says the same: "is ignored"). The example also does resize, because `card` still supplies `h=300`. Confirmed: `ImagePipe.validate/2` returns `{:ok, []}` for the plan as written, and `{:ok, [%Issue{reason: :inert_option, locations: [{:group, 0, :fit}], severity: :warning}]}` when `h` is unset too.

**Suggested wording:** "Options written in the same URL are kept. In `/preset=card/w=unset/h=unset/fit=cover`, `fit` stays, and since nothing resizes, it is ignored and listed as an [ignored option](requesting-images.md#ignored-options)."


### 4. The `image_pipe_url` README lists `mime` as a runtime dependency


**Severity:** Low. Small inaccuracy in the dependency list.

**Doc:** `image_pipe_url/README.md:8-9`
**Code:** `image_pipe_url/mix.exs:66-78`

**Evidence:** "Its only runtime dependencies are `nimble_options`, `color`, and `mime`". `deps/0` declares `nimble_options` and `color` as runtime dependencies (`boundary` is `runtime: false`), nothing in `image_pipe_url/lib` calls `MIME`, and `color` doesn't depend on `mime` either. `AGENTS.md` also lists only `nimble_options` and `color`.

**Suggested wording:** "Its only runtime dependencies are `nimble_options` and `color`; it starts no processes and loads no NIFs."


### 5. The `ImagePipe.URL.validate/1` example shows a warning that appears only with `:validate_against`


**Severity:** Low. Copying the example with a configuration like the moduledoc's returns `{:ok, []}`, not the warning shown.

**Doc:** `image_pipe_url/lib/image_pipe/url.ex:399-405`
**Code:** `image_pipe_url/lib/image_pipe/api/url.ex:158-170`

**Evidence:** The example runs `ImagePipe.URL.new(config) |> ImagePipe.URL.group(resize: [fit: :cover]) |> ImagePipe.URL.validate()` and shows `{:ok, [%Issue{reason: :inert_option, ...}]}`. `check/2` only runs the semantic checks when `config[:validate_against]` is set. Otherwise it returns only the builder's own mistakes. The only `config` defined in the moduledoc (`url.ex:5`) has just `keys` and `base_url`, and with it the call returns `{:ok, []}` (confirmed). The text below the example explains this, but the example doesn't show it.

**Suggested wording:** Define the configuration in the example:

```elixir
config = ImagePipe.URL.config(validate_against: [presets: %{}])

ImagePipe.URL.new(config)
|> ImagePipe.URL.group(resize: [fit: :cover])
|> ImagePipe.URL.validate()
```


### 6. `ImagePipe.URL` says options with several URL values take a keyword list


**Severity:** Low. Most multi-value options take a tuple or a single value, so a reader who follows the rule writes options the builder rejects.

**Doc:** `image_pipe_url/lib/image_pipe/url.ex:68-70`
**Code:** `image_pipe_url/lib/image_pipe/plan/builder/values.ex:88-178`

**Evidence:** "An option with several comma-separated values in the URL, such as `gradient`, takes a keyword list". Only the effects (`monochrome`, `duotone`, `colorize`, `gradient`, `progressive_blur`) take keyword lists. Positional values take tuples: `crop: {400, 300}`, `region: {x, y, w, h}`, `focus: {x, y}`, `zoom: {x, y}`, `anchor_offset:`/`extend_offset:`/`watermark_offset: {x, y}`, `background: {color, alpha}`, `trim: {color, tolerance}`, `crop_ratio: {16, 9}`. `padding:` takes an integer or a 2-, 3-, or 4-tuple. `detect:` takes a list of names or `{name, weight}` pairs. A keyword list for `crop:` is rejected as `:invalid_value`.

**Suggested wording:** "An effect with several comma-separated values in the URL, such as `gradient`, takes a keyword list, as in `gradient: [opacity: 0.8, color: "black", direction: :left]`. Positional values, such as `crop=400,300` or `pad=10,20`, take a tuple: `crop: {400, 300}`, `padding: {10, 20}`."


### 7. The `:validate_against` doc names `watermark_token`, which isn't a builder option


**Severity:** Low. The doc names an internal field the reader can't write or look up.

**Doc:** `image_pipe_url/lib/image_pipe/url/config.ex:45-49`
**Code:** `image_pipe_url/lib/image_pipe/plan/builder/options.ex:279-321` (no `watermark_token`), `image_pipe_url/lib/image_pipe/api/option_spec.ex:310` (`wm-enc`)

**Evidence:** "`ImagePipe.URL.config/1` raises `ArgumentError` when a preset or the request defaults ... set `watermark_source` or `watermark_token` with `request_watermarks: false`." Preset and request-default fragments are URL fragments, where these options are written `wm-src64` and `wm-enc`. The builder has `watermark_source:` and no `watermark_token:`. `:watermark_token` is the internal name the parser gives `wm-enc`.

**Suggested wording:** "... or use `wm-src64` or `wm-enc` (a `watermark_source:` in a builder) with `request_watermarks: false`."


### 8. The encoder options moduledocs refer to an imgproxy parser that doesn't exist


**Severity:** Low. Public Hex pages suggest that imgproxy's `jpgo`/`pngo`/`webpo`/`avifo` syntax or `AVIF_SPEED` is accepted, and they don't say how the structs are used.

**Doc:** `image_pipe_url/lib/image_pipe/plan/output/jpeg_options.ex:2-6`, `png_options.ex:2`, `webp_options.ex:2`, `avif_options.ex:2`
**Code:** `image_pipe_url/mix.exs:28` (published under "Encoder options"), no imgproxy parser in `image_pipe/lib` or `image_pipe_url/lib`

**Evidence:** "the imgproxy parser translates `jpgo` into this", "imgproxy `pngo` translates here", "imgproxy `avifo`/`AVIF_SPEED` translate here". `grep -rn "jpgo\|pngo\|webpo\|avifo"` finds these moduledocs and nothing else. imgproxy appears only as test reference material, as `AGENTS.md` describes. These modules are grouped as "Encoder options" in the published docs. Users meet them as the values of `jpeg_options:` and the others, in `ImagePipe.config/1` defaults and `ImagePipe.URL.output/2`, where the URL names differ for two fields (`interlace` is `progressive` in `jpeg-options`, and `subsample_mode` is `subsample`).

**Suggested wording:** For `JpegOptions`: "The JPEG encoder options of `jpeg_options:` in `ImagePipe.URL.output/2` and `ImagePipe.config/1`, and of `jpeg-options` in a URL. A field left `nil` keeps the encoder's default. In the URL, `interlace` is `progressive` and `subsample_mode` is `subsample`." Use the same pattern for PNG, WebP, and AVIF, without imgproxy names.


## Standalone server

How this was checked: at commit 6a87579 I read `image_pipe_server/README.md`, `docs/server-getting-started.md`, `docs/server-configuration.md` and `docs/server-deployment.md` in full. I compared them with every module under `image_pipe_server/lib/` and its moduledocs, the reference generator (`dev/image_pipe_server/config/reference.ex`), `config/*.exs`, `rel/env.sh.eex`, `rel/vm.args.eex`, the `Dockerfile` and `mix.exs`. I also followed the TOML conversion into the library schemas it reuses: `ImagePipe.Config`, `ImagePipe.Security`, `ImagePipe.Plug.Config`, `ImagePipe.ProcessingPool`, the File/HTTP/S3 sources and their credential providers, `ImagePipe.Cache`, `ImagePipe.Telemetry.Logger` and `ImagePipe.Response.ErrorStatus`. The reference tables between the `reference:start`/`reference:end` markers are generated from the loader's schemas, and `reference_test.exs` checks that the file matches the generator, so key names, types and schema defaults inside them can't drift. I checked the hand-written intros, the `@computed_defaults`, and all prose outside the markers. No other test reads these docs. With the toolchain, I ran `ImagePipeServer.Config.load!/2` on the "small file" example (with a real key), on the environment-variable examples, on the getting-started config without `match`, on the documented error examples, and on the TOML-error example. All of them behave as documented, except where a finding below says otherwise. The Docker run, Compose and Kubernetes examples match the image (port 8080, uid 10001, `/etc/image_pipe/config.toml`, `/var/cache/image_pipe`, `IPS_SERVER__HEALTH_PORT`/`IPS_SERVER__PORT` in the `HEALTHCHECK`). So do the allocator, `VIPS_CONCURRENCY`, `RELEASE_MODE`, distribution and tracing descriptions, which match `rel/env.sh.eex`, `config/runtime.exs` and `ImagePipeServer.Tracing`.

### 9. The configuration reference doesn't say which settings are required


**Severity:** Medium. An operator who writes a source from the reference doesn't learn that it needs these keys, and the server refuses to boot. S3 `endpoint` is the surprising case.

**Doc:** `image_pipe_server/docs/server-configuration.md:149-150` ("Every key the server accepts, generated from the loader's schemas"). The tables at `:184-189` (`adapter`, `match`), `:193-196` (file `root`, `root_id`), `:208-211` (HTTP `allowed_hosts`/`base_url`), `:243-246` (S3 `region`, `endpoint`), `:285-290` (`assume_role`), `:318-323` (`web_identity`) and `:398` (`watermarks.<name>.source`).
**Code:** `image_pipe_server/dev/image_pipe_server/config/reference.ex:192-219` (tables have only Key, Type and Default columns, and `rows/2` never reads `:required`). `image_pipe/lib/image_pipe/source/s3.ex:42-45` (`endpoint: [..., required: true]`). `image_pipe/lib/image_pipe/source/http.ex:316-321` (`allowed_hosts` is required without `base_url`). `image_pipe_server/lib/image_pipe_server/config/sources.ex:146-148` (`adapter`, `match`). `image_pipe_server/lib/image_pipe_server/config.ex:137` (watermark `source`).

**Evidence:** Each of these schemas marks the key `required: true`, or the adapter requires it. Checked with the schemas: file `[:root, :root_id]`, S3 `[:region, :endpoint]`, `assume_role` `[:base, :role_arn, :region]`, `web_identity` `[:token_file, :role_arn, :region]` (the `AWS_*` variables can fill these), cache `[:root, :max_size_bytes]`. The generated tables show these keys with an empty Default cell, exactly like optional keys that have no default (`auth_token`, `health_port`, `cache_policy.*`). Only the `[cache]` intro says "Each cache needs `root` and `max_size_bytes`." Running `load!` on an S3 source with `region` and credentials but no `endpoint` gives `invalid configuration: sources.m: required :endpoint option not found, received options: [:credentials, :region]`. An HTTP source with only `adapter` and `match` gives `sources.w: required :allowed_hosts option not found`. Neither requirement shows in the reference.

**Suggested wording:** Have the generator write `required` in the Default cell when the schema has `required: true` (in `rows/2` / `default_cell/2`). Add a line to the HTTP adapter intro: "Set `base_url`, or `allowed_hosts` for sources that take full URLs." Above the tables: "A key marked required must be set. Other keys without a default are off unless you set them."

**Question for Håvard:** Is a required `endpoint` intended for AWS S3 too, where `region` alone could give `https://s3.<region>.amazonaws.com`? If it is, the S3 table should say so plainly.


### 10. A low-priority request turned away by a full pool logs at `info`, not `error`


**Severity:** Low. With `log_level = "warning"`, an operator expects to see every `5xx`. A `503` for a `priority=low` request that a full pool turned away is filtered out.

**Doc:** `image_pipe_server/docs/server-configuration.md:431` (generated from `image_pipe_server/dev/image_pipe_server/config/reference.ex:55-60`): "`error` for a `5xx`". `image_pipe_server/docs/server-deployment.md:444-445`: "A `5xx`, or a response that failed partway through sending, logs at `error`." `image_pipe_server/docs/server-deployment.md:469-471`: "`"warning"` keeps only failed and degraded requests".
**Code:** `image_pipe/lib/image_pipe/telemetry/logger.ex:137-139`

**Evidence:** `level_for([:request, :summary], %{priority: :low, admission: admission}, base) when admission in [:overloaded, :queue_timeout], do: base`. The request line logs at the base level (`info`) even though the response is a `503`. The 0.3.0 server changelog states this on purpose: "one that a full pool turned away logs at `info` instead of `error`". The two docs didn't follow.

**Suggested wording:** In the `[telemetry]` intro and the deployment Logging section: "A `5xx`, or a response that failed partway through sending, logs at `error`. A `503` for a `priority=low` request that a full queue turned away logs at `info`." In the `log_level` bullet: "`"warning"` keeps only failed and degraded requests, except turned-away low-priority requests, and failed cache reads and writes."


### 11. Deployment says `auth_token` exempts only the health checks


**Severity:** Low. The two docs disagree. A reader of the deployment page may think `/stats` also needs the image token.

**Doc:** `image_pipe_server/docs/server-deployment.md:104-105`: "`[server] auth_token` requires `Authorization: Bearer <token>` on every request except the health checks".
**Code:** `image_pipe_server/lib/image_pipe_server/router.ex:80-85` (health checks first, then the stats endpoints with their own token, then `authorize/3`)

**Evidence:** With `[stats] enabled`, `/stats` and `/metrics` are answered before the `auth_token` check and need only the stats token. The configuration reference intro (`server-configuration.md:156`) matches the code: "requests other than the health checks, `/stats`, and `/metrics`". The deployment page itself says further down (`:257-258`) that each token "opens only its own endpoints".

**Suggested wording:** "`[server] auth_token` requires `Authorization: Bearer <token>` on every request except the health checks and the [stats endpoints](#cache-stats), answering `401` otherwise."


### 12. `/stats` doesn't answer `503` for the whole startup and shutdown


**Severity:** Low. An operator who reads a `200` from `/stats` as "the server takes traffic" gets the wrong answer. The doc implies `/stats` follows readiness, and it doesn't.

**Doc:** `image_pipe_server/docs/server-deployment.md:315-316`: "Both endpoints answer `503` while the server starts up and while it shuts down."
**Code:** `image_pipe_server/lib/image_pipe_server/stats.ex:73-83` (503 only when `ImagePipe.cache_stats/1` raises because no instance is published). `image_pipe_server/lib/image_pipe_server/application.ex:79-84` and `:121-134` (child order and `prep_stop`).

**Evidence:** The `503` comes only from `ImagePipe.cache_stats/1` raising `ArgumentError` when the instance isn't running (commit 6457ef5: "The health listener starts before the ImagePipe instance and stops after it"). The image listener starts after the instance, so it never answers `503` from `/stats`: before it starts it refuses connections. During the warmup, the instance runs while `/health/ready` still says `503 starting`, so `/stats` on the `health_port` listener answers `200`. During `shutdown_delay` and the listener drain, the instance still runs, so `/stats` answers `200` on both listeners. Only on the `health_port` listener, before the instance starts and after it stops, is the answer `503`.

**Suggested wording:** "On the [`health_port`](server-configuration.md#server) listener, both endpoints answer `503` before the image processing starts and after it stops during shutdown."


### 13. Some boot errors don't name the setting or start with `invalid configuration:`


**Severity:** Low. An operator who searches the log for `invalid configuration` misses some errors, and a few errors don't say which setting to fix.

**Doc:** `image_pipe_server/docs/server-configuration.md:125-134`: "The server prints the error, which names the setting or variable", followed by examples that all start with `invalid configuration:`.
**Code:** `image_pipe_server/lib/image_pipe_server/config.ex:490-503` (`library!/2` re-raises the library's `ArgumentError` message unchanged unless it starts with `invalid source <name>: `). `image_pipe_url/lib/image_pipe/security.ex:120-121`. `image_pipe/lib/image_pipe/cache.ex:76`.

**Evidence:** Output of `load!` with the toolchain:
- `IPS_URL__SOURCE_ENCRYPTION_KEYS` without `keys` gives `source encryption requires signing keys`, with no prefix and no setting path.
- An `input.root` inside `output.root` gives `invalid cache config: :cache_pools_require_separate_roots`, which names neither setting.
- A watermark whose source no mount serves gives `invalid ImagePipe configuration: watermark logo: no configured source serves this path`.
- `max_effort.webp = 3` gives `invalid ImagePipe configuration: max_effort: webp: 3 is below the configured webp_options effort 4`.

The server-side checks do follow the documented form, for example `invalid configuration: processing.qualty: unknown setting`.

**Suggested wording:** "Invalid configuration stops the server at boot. The server prints the error and exits with status 1. Errors from the file's shape and types name the setting, such as `processing.qualty`. Errors from the library's own checks describe the problem in the library's terms." Keep the examples.

**Question for Håvard:** Should `library!/2` add the `invalid configuration:` prefix and map `:cache_pools_require_separate_roots` and the encryption-key error to `cache.input.root` and `url.source_encryption_keys`, so the doc's claim holds?


### 14. "Without Docker" leaves out the Rust toolchain the build needs


**Severity:** Medium. Following the section on a machine without `cargo` fails the build.

**Doc:** `image_pipe_server/docs/server-deployment.md:567-573`: "Build a release from `image_pipe_server/`: `MIX_ENV=prod mix release`".
**Code:** `image_pipe_server/mix.exs:60-70` (the sibling `image_pipe_svg` path dependency plus `rustler`, unless `IMAGE_PIPE_LIBS=hex`). `image_pipe_server/config/config.exs:109-112` (`force_build: image_pipe_svg: System.get_env("IMAGE_PIPE_LIBS") != "hex"`). `image_pipe_server/Dockerfile:105-110` (the image installs rustup for this mode).

**Evidence:** Without `IMAGE_PIPE_LIBS=hex`, the release builds against the sibling projects and compiles the `image_pipe_svg` NIF from Rust source, which needs `cargo`. The Dockerfile installs Rust for exactly this case ("so does the sibling image_pipe_svg project"). The doc mentions neither the toolchain nor `IMAGE_PIPE_LIBS=hex`, which builds against the published `image_pipe` version and downloads the precompiled NIF. The command also needs `mix deps.get` first.

**Suggested wording:** "Build a release from `image_pipe_server/`. `IMAGE_PIPE_LIBS=hex` builds against the `image_pipe` release the server ships with and downloads the SVG renderer precompiled. Without it, the build uses the sibling projects and needs a Rust toolchain."

```bash
export IMAGE_PIPE_LIBS=hex MIX_ENV=prod
mix deps.get --only prod
mix release
```


### 15. `copy = "keep"` points at a "`[cache] input` pool" and doesn't say it needs one


**Severity:** Low. The table name is wrong, and a reader isn't told that `copy = "keep"` does nothing useful without `[cache.input]`. The server boots without complaint.

**Doc:** `image_pipe_server/docs/server-deployment.md:233-234`: "`copy = "keep"` keeps local copies of originals in the `[cache] input` pool."
**Code:** `image_pipe/lib/image_pipe/source/file.ex:52-55` ("Needs `:input_cache` configured."). `image_pipe_server/lib/image_pipe_server/config.ex:238-239` (the TOML table is `[cache.input]`).

**Evidence:** The setting is `[cache.input]`, as written at `server-deployment.md:223`. "Pool" is internal vocabulary. A file source with `copy = "keep"` and no `[cache.input]` loads without error (checked with `load!`).

**Suggested wording:** "On a network filesystem such as EFS, `copy = "keep"` keeps a local copy of each original in the `[cache.input]` cache, which you must configure."


### 16. Server moduledocs leave out settings and the `401` before the `404`


**Severity:** Low. These moduledocs list the sections' settings, and they no longer list all of them.

**Doc:** `image_pipe_server/lib/image_pipe_server/config.ex:19-20` (`[cache]` lists `output`, `input`, and `storage_inputs`). `image_pipe_server/lib/image_pipe_server/config.ex:28-32` (`[telemetry]` lists `log_level`, `log_requests`, `log_colors`, `trust_traceparent`, and `trust_request_id`). `image_pipe_server/lib/image_pipe_server/router.ex:6`: "Requests outside the mount path answer 404."
**Code:** `image_pipe_server/lib/image_pipe_server/config.ex:236-243` (`max_remembered_originals`). `image_pipe_server/lib/image_pipe_server/config.ex:121-129` (`log_stages`, `log_format`). `image_pipe_server/lib/image_pipe_server/router.ex:83-98` (with `:auth_token_hash`, `authorize/3` runs before `route/3`, so an unauthenticated request outside the mount path gets `401`).

**Evidence:** `max_remembered_originals` (added in #1019), `log_stages` and `log_format` are accepted but missing from the section list. The router answers `401` first when an auth token is set.

**Suggested wording:** In `config.ex`: "`[cache]` - `output` and `input` file system caches, `storage_inputs` as `[{ header = "..." }, { cookie = "..." }]`, and `max_remembered_originals`." Add to `[telemetry]`: "`log_stages` adds a line per stage, and `log_format` picks text or a JSON format." In `router.ex`: "Requests outside the mount path answer 404, after the auth token check when there is one."


## Caching, freshness, delivery, errors, and debug headers

How this was checked: commit 6a87579 (`main`, after #1056). Docs read in full: `image_pipe/docs/cache.md`, `caching-processed-images.md`, `caching-and-freshness.md`, `cdn-http-cache.md`, `serving-through-a-cdn.md`, `debug_headers.md`, `streaming-failures.md`, `errors.md`, `deployment.md`, plus the cache parts of `telemetry-events.md`. Module docs checked: `ImagePipe.Cache.FileSystem` (and the `Store` option schema it renders), `ImagePipe.Source.CachePolicy`, `ImagePipe.Source.CacheSettings`, `ImagePipe.ProcessingPool`, the `ImagePipe.Instance` schema, `ImagePipe.cache_stats/1`, `ImagePipe.Plug.StreamAbortedError`, and the `cache`, `input_cache` and `max_remembered_originals` docs in `ImagePipe.Config`. Code traced: `cache.ex`, `cache/**` (Admission, Memo, Store, Sweep, Owner, OwnerWatch, Writers, Writer, Sink, Publication, OutputWork, Work, Input, SourceRecords, RecentTable, Lookups), `representation/**`, `execution/identity.ex`, `execution.ex` and `execution/source_cache.ex` (coalescing, records), `response/**`, `delivery/**`, `debug/**`, `plug/errors.ex`, `plug/runner.ex`, `source/cache_*.ex`. The #1019/#1020/#1049/#1056 drift (records in memory, `entries` counting, memo, admission timeouts, doorkeeper, owner file timings, stats fields) was checked line by line and the docs match the code there. Runtime checks were run with scripts under the scratchpad (`caching/*.exs`): cache-key debug header without a cache, `miss`/`hit` and `HEAD` fill through an instance, `cache_stats/1` shape, error statuses and bodies, ETag/cache-key changes for config options, root overlap error, `pool` override.

### 17. `X-ImagePipe-Cache-Key` is sent when no cache is configured


**Severity:** Medium. Someone checking whether caching is set up reads a present cache key as proof that a cache is in use.

**Doc:** `image_pipe/docs/debug_headers.md:103`
**Code:** `image_pipe/lib/image_pipe/execution.ex:571` (key set whenever the response is storable, with or without a cache), `image_pipe/lib/image_pipe/execution.ex:476-481` (`coalesce/2` calls `make/2` for `cache: nil`), `image_pipe/lib/image_pipe/delivery.ex:104`, `image_pipe/lib/image_pipe/plug/runner.ex:257-264` (complete bodies always pass `context.representation.cache_key.hash`)

**Evidence:** The doc says: "`X-ImagePipe-Cache-Key` ... Absent on a generated image that won't be stored, such as when no cache is configured". In `make/4`, `key = if store? and storable?(context), do: context.representation.cache_key`. `storable?/1` checks only the source's storage permission and `internal_cache`, not whether `:cache` is set, so the key reaches `Delivery.stream/4` and the header. The `delivery.ex:59` comment ("`cache_key` is `nil` when the request runner has no cache configured") is also stale. For `output=info`, BlurHash and LQIP responses the key is passed unconditionally. A runtime check with an inline `ImagePipe.Plug` (no instance, no cache) and `allow_debug_headers: true` returned `x-imagepipe-cache: miss` and a 64-character `x-imagepipe-cache-key` for both `/w=20/debug/src/a.jpg` and `/output=info/debug/src/a.jpg`. The header is absent only when the source or a watermark may not be stored (and for a degraded detection fallback).

**Suggested wording:** "| `X-ImagePipe-Cache-Key` | `a1b2c3…` | The response's cache key, 64 hexadecimal characters. Absent when the image may not be stored, such as when its source denies storage. It is sent even when no cache is configured, so use `X-ImagePipe-Cache` to see whether the cache served the response |"

**Question for Håvard:** Should the code leave the key out when no `cache` is configured (as the doc and the `delivery.ex` comment say), or should the doc follow the code?


### 18. The cache key and ETag lists leave out host output settings and watermark images


**Severity:** Medium. Changing a configured quality or metadata setting replaces every cached copy and every client's `ETag`, and these pages present their lists as complete.

**Doc:** `image_pipe/docs/cache.md:71-95`, `image_pipe/docs/cdn-http-cache.md:189-201`
**Code:** `image_pipe/lib/image_pipe/execution/identity.ex:42-49,73-82` (orient, page, groups, selection, `output_policy`, SVG material, detector), `image_pipe/lib/image_pipe/output/policy.ex:277-310` (`identity_material/1`: `quality`, `default_quality`, `format_qualities`, `quality_search`, `strip_metadata`, `keep_copyright`, `dpi`, `color_profile`, `hdr`, `encoder_options`, `skip_formats`, `max_search_pixels`), `image_pipe/lib/image_pipe/execution/identity.ex:129-145` and `image_pipe/lib/image_pipe/execution/watermarks.ex:123-128` (watermark source identity and byte identity)

**Evidence:** `cache.md` says "Each stored response is selected by:" and lists the original's version, processing options, output format, detector, cachebuster, `storage_inputs`, and origin credentials. `cdn-http-cache.md` says the `ETag` "changes when any of these change" with the same first four. The representation material, which feeds both, also holds the resolved output policy built from host configuration, the SVG renderer settings, the selected page, and each watermark's source identity, with the watermark originals' byte identities joined into the byte identity. A runtime check with the same URL `/w=40/format=jpeg/debug/src/a.jpg` gave a different `ETag` and cache key with `quality: 50` and with `strip_metadata: false` than with defaults. `deployment.md:161` already says `max_search_pixels` is part of the key, which neither list mentions.

**Suggested wording:** Add to the `cache.md` list (and the matching items to the `ETag` list in `cdn-http-cache.md`):

"- The version of each watermark image the request uses.
- The output settings in your configuration that change the encoded bytes, such as `quality`, `format_quality`, `strip_metadata`, the encoder options, and, for a request that searches for a quality, `max_search_pixels`. Changing one of them makes new entries for the requests it affects."


### 19. A stopped request isn't killed after one second when a processing pool runs


**Severity:** Low. Readers plan for a one-second cleanup bound that doesn't hold in the default setup, where the slot stays taken until libvips finishes.

**Doc:** `image_pipe/docs/streaming-failures.md:84-85`, `image_pipe/docs/streaming-failures.md:99-101`
**Code:** `image_pipe/lib/image_pipe/delivery/coordinator.ex:13-15,434-449`, `image_pipe/lib/image_pipe/processing_pool.ex:571-572`, `image_pipe/lib/image_pipe/instance.ex:133-143`

**Evidence:** The doc says the request "releases the processing pool slot" and "a stopped request gets one second to clean up before it is killed". The coordinator comment says "Pooled producers halt cooperatively and keep their slot through bracket cleanup. Unpooled producers retain the force-kill backstop." With a pool, `request_producer_halt/3` calls `ProcessingPool.cancel/2`, which only marks an active job `:cancelled`. The worker keeps its slot until it returns. The kill timer (`max(100, div(@cancel_timeout, 2))`, one second) is set only when `:processing_pool` is nil. An instance starts a pool unless `pool: false`, and `image_pipe_server` always runs one. The `ImagePipe.ProcessingPool` moduledoc already says "Workers finishing after a timeout or cancellation keep their slots until their operations and cleanup finish."

**Suggested wording:** "The work stops between chunks, not instantly. A libvips operation that is already running finishes first. With a processing pool, the request keeps its slot until that operation and its cleanup finish. Without a pool, a stopped request gets one second to clean up before it is killed." At line 85, replace "releases the processing pool slot" with "frees its processing pool slot once that work has stopped".


### 20. Not every request waiting for the same original gets a `504`


**Severity:** Low. The guide describes `504`s that requests for the same image never return without an originals cache.

**Doc:** `image_pipe/docs/deployment.md:203-205`
**Code:** `image_pipe/lib/image_pipe/execution.ex:214-249` (download flight waiter falls back to `resolve_record(context, &acquire(context, &1))`), `image_pipe/lib/image_pipe/execution/source_cache.ex:191-200,243` (the `504` path, only with an originals cache)

**Evidence:** The doc says "Other requests waiting for the same original give up after waiting `fetch_timeout` plus one second, with `504`." Identical requests for a new image wait on a download flight (`OutputWork.join_download/4`). When that wait ends, `joined_download/2` falls through to fetching the original itself, with no error. The `{:source, :receive_timeout}` (`504`) path is `Work.run` in `SourceCache.input/5`, which is used only when an originals cache is configured. `cache.md:198-212` and `errors.md` (504 row) describe this correctly.

**Suggested wording:** "With an originals cache, a request waiting for another request's download of the same original gives up after `fetch_timeout` plus one second, with `504`. Without one, a request for the same image stops waiting then and downloads the original itself (see [coordination limits](cache.md#coordination-limits))."


### 21. Lowering the result size limits doesn't replace cached images or change `ETag`s


**Severity:** Low. After lowering `max_result_width`, larger images made earlier keep being served, and clients holding them get `304`s.

**Doc:** `image_pipe/docs/cache.md:131-133`, `image_pipe/docs/deployment.md:46-47`
**Code:** `image_pipe/lib/image_pipe/execution/identity.ex:61-82` (no result limits in image identity), AGENTS.md cache guideline ("Keep safety limits ... static result dimension limits ... out of both")

**Evidence:** `cache.md` says "Making a new processed image from a stored original applies the current `max_body_bytes` and pixel limits. Processed images already in the cache are still served after you lower those limits." It names no result limits. A runtime check of `/w=40/format=jpeg/src/a.jpg` gave a 40-pixel-wide image by default and a 30-pixel-wide one with `max_result_width: 30`, with the same `ETag` and cache key. This is the intended design. The pages just don't say it applies to `max_result_width`, `max_result_height` and `max_result_pixels`.

**Suggested wording:** In `cache.md`: "Making a new processed image applies the current `max_body_bytes`, pixel limits, and `max_result_width`, `max_result_height`, and `max_result_pixels`. These limits aren't part of the cache key or the `ETag`, so processed images already in the cache are still served after you lower them." In `deployment.md` after line 47: "Images already cached keep their size after you lower these limits (see [Originals cache](cache.md#originals-cache))."


### 22. The `root` option says Plug initialization fails for overlapping roots


**Severity:** Low. Caches can no longer be configured on a Plug, so readers look for the error in the wrong place.

**Doc:** `image_pipe/lib/image_pipe/cache/file_system/store.ex:22-28` (rendered into the `ImagePipe.Cache.FileSystem` moduledoc)
**Code:** `image_pipe/lib/image_pipe/cache.ex:62-80`, `image_pipe/lib/image_pipe/cache/input.ex:21-42`, `image_pipe/lib/image_pipe/config.ex:706-718`

**Evidence:** The doc says "The `cache` and `input_cache` roots must be separate, neither inside the other. Plug initialization fails otherwise." Since caches need an instance, `ImagePipe.Plug.init/1` raises for any `cache` option. A runtime check showed `ImagePipe.child_spec(name: ..., cache: [root: "/tmp/rc", ...], input_cache: [root: "/tmp/rc/in", ...])` raising `ArgumentError` "invalid cache config: :cache_pools_require_separate_roots".

**Suggested wording:** "Directory that holds the cache files. Must be an absolute path. The `cache` and `input_cache` roots must be separate, neither inside the other. `ImagePipe.config/1` and `ImagePipe.child_spec/1` raise `ArgumentError` otherwise."


### 23. The `pool` cache option can't be set the way its doc says


**Severity:** Low. The option looks like a choice, but `input_cache` ignores it, and on `cache` it relabels only some events.

**Doc:** `image_pipe/lib/image_pipe/cache/file_system/store.ex:30-38`
**Code:** `image_pipe/lib/image_pipe/cache/input.ex:21-22` (`Keyword.put(pool, :pool, :input)`), `image_pipe/lib/image_pipe/cache/sink.ex:137,315`, `image_pipe/lib/image_pipe/cache/writer.ex:148`, `image_pipe/lib/image_pipe/cache.ex:404-406` (lookup, write and stage events hard-code `pool: :output`), `image_pipe/lib/image_pipe/cache/file_system/store.ex:69-79` (Admission and sweep take `:pool` from the options)

**Evidence:** The doc says the option "Tags the cache's telemetry events with `pool` ... Defaults to `:output`, or `:input` for a cache configured as `:input_cache`." `Input.validate_config/1` overwrites the value, so a runtime check with `input_cache: [..., pool: :output]` produced `[pool: :input, ...]`. On `cache`, `pool: :input` changes only the admission, eviction and sweep events. The lookup, write and stage events still carry `pool: :output`.

**Suggested wording:** Either hide the option (`doc: false`) or document what it does: "Set by the cache's role: `:output` for `cache` and `:input` for `input_cache`. Its value tags the cache's admission, eviction, and sweep events."

**Question for Håvard:** Is `:pool` meant to be a user option at all? If not, it could leave the public schema.


### 24. `errors.md` omits the fixed-body `400` responses


**Severity:** Low. Readers expect a list of problems in every `400` body and won't find the output-option conflict case.

**Doc:** `image_pipe/docs/errors.md:34`
**Code:** `image_pipe/lib/image_pipe/plug/errors.ex:62-76`, `image_pipe/lib/image_pipe/output/policy.ex:102-111`

**Evidence:** The `400` row says the request "fails validation ... or names a source scheme that no configured source serves" and "The body lists the problems." A runtime check returned `400` with the body `invalid source` for `/w=20/src/s3://bucket/a.jpg` on a file-only mount, and `400` with the body `invalid output` for `/w=20/format=avif/profile=srgb/hdr=preserve/src/bad.jpg`. Output options that can't be combined (`{:invalid_output, _}`, also raised for encoder effort above `max_effort`) aren't named in the table.

**Suggested wording:** Add to the `400` row: "Output options that can't be combined, such as `profile=srgb` with `hdr=preserve`, or encoder effort above `max_effort`, get the body `invalid output`. A source scheme that no configured source serves gets `invalid source`. Other validation failures list the problems in the body."


### 25. The leftover cleanup keeps metadata files it can't read


**Severity:** Low. An operator who fixes permissions expects the cleanup to remove those files, but it never does.

**Doc:** `image_pipe/docs/cache.md:291-293`
**Code:** `image_pipe/lib/image_pipe/cache/file_system/sweep.ex:1-10,94-99`

**Evidence:** The doc says "Metadata files the cache can't read, such as ones another ImagePipe version wrote, count as left behind too". `unreadable?/1` returns true only for `{:invalid_metadata, _}` (a file that reads but doesn't decode). The module comment says "A metadata file it can't read, as on a permission or I/O error, stays."

**Suggested wording:** "Metadata files the cache can't decode, such as ones another ImagePipe version wrote, count as left behind too, and so do their bodies. A metadata file that can't be read at all, for example because of its permissions, stays."


### 26. The memory guide leaves out the instance's long-lived memory


**Severity:** Low. Readers sizing a node for a large cache miss up to about 1 GB of remembered originals plus up to about 300 MB of entry metadata per cache.

**Doc:** `image_pipe/docs/deployment.md:225-246`
**Code:** `image_pipe/lib/image_pipe/cache.ex:118-125` (`max_remembered_originals` default, up to 1,000,000), `image_pipe/lib/image_pipe/config.ex:428-441` (about 700 bytes to 1 KB each), `image_pipe/lib/image_pipe/cache/file_system/memo.ex:23-26` (up to 200,000 rows at about 1.5 KB per cache root)

**Evidence:** The "Memory" section covers decoded images and the libvips operation cache only. An instance also keeps its remembered originals in memory, one per 50 KB of `cache` `max_size_bytes` (1,000,000 records, about 1 GB, from a 50 GB cache), and each cache root keeps entry metadata for recent hits (up to about 300 MB for a cache of 10 GB or more). Both are documented elsewhere (`caching-and-freshness.md:41-49`, `cache.md:323-328`, the `max_remembered_originals` option doc), but not where readers plan memory.

**Suggested wording:** Add a paragraph: "An instance with caches also holds memory that doesn't depend on traffic. It remembers originals in memory, about 1 KB each, one for each 50 KB of the processed-image cache's `max_size_bytes` (see `max_remembered_originals` in `ImagePipe.config/1`). Each cache keeps the metadata of recently served entries, up to about 300 MB (see [cache process and restarts](cache.md#cache-process-and-restarts))."


## URL option reference and processing semantics

How this was checked: at commit 6a87579 I read `image_pipe/docs/processing.md`, the six pages under `image_pipe/docs/processing/`, `processing-order.md`, `urls.md`, `requesting-images.md`, `processing-controls.md`, `choosing-an-autoquality-target.md` and `content-aware-gravity.md`. I compared them with the URL grammar (`image_pipe_url/lib/image_pipe/api/option_spec.ex`, `api/value.ex`, `api/output_options.ex`, `api/parser.ex`, `api/path.ex`, `plan/value_spellings.ex`, `plan/value_bounds.ex`), the plan model and validation (`plan/spec.ex`, `plan/spec/validation.ex`, `plan/presets.ex`, `plan/builder/*.ex`, `plan/output/*.ex`), request parsing and errors (`image_pipe/lib/image_pipe/plug/request.ex`, `plug/errors.ex`, `response/error_status.ex`, `response/disposition.ex`), the executor and operations (`transform/executor.ex`, `transform/executor/geometry.ex`, `transform/operation/*.ex`, `transform/focal.ex`, `transform/clamp.ex`), output (`output/policy.ex`, `output/negotiation.ex`, `output/encode_search.ex`, `processing.ex`, `processing/terminal.ex`) and the defaults in `config.ex`. I built the full option table from `OptionSpec.all/0` and checked it against the docs in both directions. Every key, value shape, range, default and enumerated spelling matches, apart from the gaps listed below. I ran all 98 example URLs in these pages through `ImagePipe.API.Path.extract/2` and `ImagePipe.API.Parser.parse/2`. Each one parses and warns about ignored options as the docs say, apart from the deliberate error examples. I also ran about 50 edge-case URLs to check the `400` and "ignored" promises. I evaluated all 73 Elixir builder examples with `ImagePipe.URL.url_with_issues/3`, and each one parses to the same `Spec` as its URL tab. Every relative link and anchor in these pages resolves. I checked the stage order, effect order, DPR, cover, contain, min and zoom arithmetic in the worked examples, the format negotiation rules, quality defaults (80, WebP 79, AVIF 56), autoquality rails and target, encoder field names, and error statuses against the code. All of them match except for the findings below.

### 27. `kernel` is said not to apply to the result-limit scale-down, but it does


**Severity:** Medium. A user who picks `kernel=nearest` for pixel art is told the scale-down to the output limits stays smooth. It actually uses nearest too, and the reverse holds for users who expect lanczos3 there.

**Doc:** `image_pipe/docs/processing/resize.md:204-206`
**Code:** `image_pipe/lib/image_pipe/processing.ex:228-233`, `image_pipe/lib/image_pipe/transform/executor.ex:305-314`, `image_pipe/lib/image_pipe/transform/clamp.ex:49`

**Evidence:** The doc says: "`kernel` applies to the resize of its own group. Rotation, `pixelate`, watermarks, placeholder outputs, and the scale-down to the maximum output size keep their own resampling." Since `ce3f80a` ("Resize clamped results with the resize operation's resampler"), `Processing.prepare_pixels/7` calls `Clamp.clamp_with_telemetry(..., [kernel: Executor.result_kernel(request)] ++ config)`. `result_kernel/1` is documented as "the kernel of the last group that resizes, or lanczos3", and `Clamp.clamp/3` resamples with `Keyword.get(opts, :kernel, :lanczos3)`. The library CHANGELOG `Unreleased` entry says the same: "An image scaled down to fit `:max_result_width`, ... uses the request's `kernel`. Before, ... a `kernel=nearest` result was smoothed." The other items in the doc's list (rotation, pixelate, watermarks via `Watermark.resize/3` with `:lanczos3`, placeholders via `%Resize{}` defaults) are correct.

**Suggested wording:** "`kernel` applies to the resize of its own group. The scale-down to the maximum output size uses the `kernel` of the last group that resizes. Rotation, `pixelate`, watermarks, and [placeholder outputs](output.md#output) keep their own resampling."


### 28. "Requesting images" says an option with no effect fails with `400`, but it is ignored


**Severity:** Medium. The page contradicts itself and every option page. A user who reads it expects a typo such as `fit=cover` without `w` to be reported, but the server serves the unprocessed image.

**Doc:** `image_pipe/docs/requesting-images.md:35-38` (and the "Ignored options" section of the same page, `:346-352`, which is correct)
**Code:** `image_pipe_url/lib/image_pipe/plan/spec/validation.ex:250-251`, `image_pipe_url/lib/image_pipe/plan/spec.ex:56-71`

**Evidence:** Lines 35-38 say: "ImagePipe rejects a URL with `400` when it has an unknown option, the same option twice in one group, options that conflict, or an option that has no effect, such as `fit=cover` without a width or height". In the code, `severity(:inert_option)` is `:warning`, and `Spec.settle/5` drops warnings and returns `{:ok, ...}`. Only `:error` issues fail the parse. A parse run confirms it: `/fit=cover/src/photos/beach.jpg` parses OK with `ignored_keys == ["fit"]`. The page's own "Ignored options" section says the same URL "serves the same image as `/src/photos/beach.jpg`". So do `resize.md`, `crop.md` and `watermark.md`, which describe such options as "ignored".

**Suggested wording:** "ImagePipe rejects a URL with `400` when it has an unknown option, the same option twice in one group, or options that conflict. An option that has no effect, such as `fit=cover` without a width or height, is [ignored](#ignored-options). It also rejects:"


### 29. The option index leaves out `priority`


**Severity:** Low. The index on `processing.md` is meant to list every URL option, and `priority` is missing from it.

**Doc:** `image_pipe/docs/processing.md:23`
**Code:** `image_pipe_url/lib/image_pipe/api/option_spec.ex:465-470`

**Evidence:** The "Request controls" row lists `filename`, `attachment`, `cb`, `expires`, `debug`. `OptionSpec.all/0` also declares `priority` (request scope), and `processing/request.md:171-214` documents it. Every other key in `OptionSpec.all/0` appears in the index.

**Suggested wording:** `| [Request controls](processing/request.md) | `filename`, `attachment`, `cb`, `expires`, `priority`, `debug` |`


### 30. The 64-segment limit also counts `-` separators


**Severity:** Low. A multi-group URL can fail with fewer than 64 options, which the doc doesn't explain.

**Doc:** `image_pipe/docs/requesting-images.md:44`
**Code:** `image_pipe_url/lib/image_pipe/api/path.ex:155-174` (`@max_option_segments 64`, counted for every non-source segment)

**Evidence:** The doc says the server rejects "More than 64 option segments." The lexer counts every segment before `src/`, `src64/` or `enc/`, including `-` separators and invalid segments. A parse run with 33 options in 33 groups (65 segments) fails with `too many option segments (max 64)`. `ImagePipe.URL.url/3` already describes the limit as "more than 64 option and `-` segments".

**Suggested wording:** "More than 64 segments before `src/`, counting each `-` as a segment."


### 31. The `dpr` reference omits the watermark sizes it multiplies


**Severity:** Low. The `dpr` section presents a complete list of what it scales, but watermark sizes are missing from it.

**Doc:** `image_pipe/docs/processing/resize.md:233-236`, `image_pipe/docs/processing-order.md:95-96`
**Code:** `image_pipe/lib/image_pipe/transform/executor.ex:888-905` (`watermark_size/4` with `scale == nil` multiplies the asset's size by the group's DPR, and `placement_length/3` multiplies pixel `wm-offset` and `wm-gap` by it)

**Evidence:** `resize.md` says `dpr` "Multiplies the sizes you request in pixels: `w`, `h`, `min-w`, `min-h`, the `extend` canvas, `pad`, `extend-offset`, and an `anchor-offset` on a cover resize." The executor also multiplies a watermark's natural size (without `wm-scale`) and pixel `wm-offset` and `wm-gap` values by the group's effective DPR. `watermark.md` documents this per option, but the `dpr` reference reads as complete.

**Suggested wording:** "Multiplies the sizes you request in pixels: `w`, `h`, `min-w`, `min-h`, the `extend` canvas, `pad`, `extend-offset`, an `anchor-offset` on a cover resize, and a watermark's size (without `wm-scale`), `wm-offset`, and `wm-gap`."


### 32. An unknown `detect` class is accepted when the server has no detector


**Severity:** Low. A reader may rely on the `400` to catch class typos, but a server without a detector serves an attention crop instead.

**Doc:** `image_pipe/docs/content-aware-gravity.md:239-241`, `image_pipe/docs/processing/crop.md:374-375`
**Code:** `image_pipe/lib/image_pipe/processing.ex:83-103` (`check_known_classes/2`: `{_named, nil} -> :ok`)

**Evidence:** `content-aware-gravity.md` says: "A class the detector doesn't know, such as `detect=unicorn`, fails with `400` before the image is fetched, whether or not detection is required." `check_known_classes/2` returns `:ok` when `detector` is `nil`, so on a server without a detector `detect=unicorn` is served with the attention fallback. `crop.md`'s "A class the server's detector doesn't support" is closer, but it doesn't mention this case either.

**Suggested wording:** add to the `content-aware-gravity.md` sentence: "On a server without a detector, every class is accepted and the crop uses attention cropping."

**Question for Håvard:** Should a server with no detector also reject classes outside the bundled detector's list, so typos fail the same way everywhere? If so, the code is what needs to change.


## Getting started, configuration, Plug mounting, and sources

How this was checked: Commit `6a87579`. Docs: root `README.md`, `image_pipe/README.md`, and `image_pipe/docs/` `index.md`, `installation.md`, `phoenix-getting-started.md`, `configuration.md`, `sources.md`, `serving-local-files.md`, `serving-from-http.md`, `serving-from-s3.md`, `source-network-policy.md`, `custom-sources.md`. Moduledocs and option docs: `ImagePipe` (`config/1`, `child_spec/1`, `run/4`), `ImagePipe.Config`, `ImagePipe.Plug` and `ImagePipe.Plug.Config`, `ImagePipe.Instance`, `ImagePipe.Source` and every `ImagePipe.Source.*` module (File, HTTP incl. AddressPolicy/TargetGuard/PinnedTarget/DnsCache, S3 incl. Credentials/RefreshCache/CredentialWarmup and the four providers, CacheSettings, CachePolicy, Resolved, Response, Path, URL, Object, Routes, Parser, ReqStream, ReqSanitizer, Input), `ImagePipe.Decode*`, `ImagePipe.Application`, `ImagePipe.SafePath`, `image_pipe/mix.exs`, `image_pipe_url/mix.exs`, plus `ImagePipe.Response.ErrorStatus` and `ImagePipe.Plug.Errors` for status codes. Runtime checks with `mix run`: the `custom-sources.md` adapter compiles and serves `200` for `/w=400/src/blobs/42` and `/w=400/src/blob://42` and `404 source not found` for `/blobs/43`; every Elixir source example in `sources.md`, `serving-from-http.md`, `serving-from-s3.md` (including all credential forms, buckets, and the HTTP/2 and function `address_policy` forms in `ImagePipe.Source.HTTP`) builds a configuration; the Phoenix guide's `400` diagnostic for a missing `src/`, its `404 source not found`, and its `fit: :bogus` message match; the README `run/4` example returns `image/webp`; `2130706433`, `0x7f.1`, and `127.1` parse as `127.0.0.1`. Option schemas were compared with the docs in both directions (defaults, types, units), and error statuses were traced to `ErrorStatus`. Installation versions (`~> 0.3.0`, Elixir `~> 1.18`, `req ~> 0.8.0-rc.0`) match `@version` and `mix.exs`. Markdown link targets and anchors in these docs resolve.

### 33. `run/4` claims a source content-type policy that doesn't exist


**Severity:** Medium. An operator reading this would think an HTTP origin's `Content-Type` is checked, and rely on that, when no adapter looks at it.

**Doc:** `image_pipe/lib/image_pipe.ex:212-213`
**Code:** `image_pipe/lib/image_pipe/source/req_stream.ex:115-130`, `image_pipe/lib/image_pipe/source/http.ex:486-508`

**Evidence:** The `{:source, source}` input says "The source's network, redirect, timeout, and content-type policies apply." No source code reads the response's `content-type`. `ReqStream` accepts any 2xx response, and its only response check is the optional `:validate_response` hook, which only S3 sets, to compare `x-amz-version-id` (`s3.ex:299`). `ImagePipe.Source.HTTP` has no content-type option. What actually guards the bytes is the decode step's signature check (`Decode` rejects families such as BMP and ICO by magic bytes, `decode.ex:45`), which is independent of the header. `git log -S` finds no content-type check in `source/` in the repository history.

**Suggested wording:** "The source's network, redirect, and timeout settings apply." If the decode-side check is worth mentioning: "ImagePipe checks the bytes, not the origin's `Content-Type`, so the original must be an image format ImagePipe accepts (see [Native format support](installation.md#native-format-support))."

**Question for Håvard:** `AGENTS.md` (Request safety guidelines) also says source fetching uses "bounded redirects/timeouts/content-type/body limits". Is a content-type check intended for the HTTP source, or should both texts drop it?


### 34. File sources answer 404 for absolute symlinks, even ones that point inside the root


**Severity:** Medium. A directory laid out with absolute symlinks (a common deploy pattern, such as `current -> /srv/releases/2026-10-01`) serves `404 source not found` for every image under the link, and the docs give no hint why.

**Doc:** `image_pipe/lib/image_pipe/source/file.ex:70-72`, `image_pipe/docs/serving-local-files.md:9-42`
**Code:** `image_pipe/lib/image_pipe/safe_path.ex:2-8,32-37,48-57`, `image_pipe/lib/image_pipe/source/file.ex:210-217`

**Evidence:** The File moduledoc says only "Paths can't leave the root. A path that names no regular file is not found." `SafePath.relative/2` follows the rules of `Path.safe_relative/2`: an absolute link target is unsafe, and so is a relative link that climbs above the root. `safe_path/2` turns that into `{:source, :denied_path}`, which `ErrorStatus` maps to `404 source not found`. Tested at runtime with a root holding `real/a.jpg`, `rel -> real`, `abs -> <root>/real`, and `absfile.jpg -> <root>/real/a.jpg`: `real/a.jpg` and `rel/a.jpg` answer `200`, `abs/a.jpg` and `absfile.jpg` answer `404`, though both targets are inside the root. Neither the moduledoc nor the guide mentions symlinks.

**Suggested wording:** In the File moduledoc after "Paths can't leave the root.": "Symbolic links are followed only when they are relative and stay inside the root. A path through an absolute link, or a link that leads outside the root, is not found." Add the same sentence to `serving-local-files.md` under "Add a file source".


### 35. `fetch/3` docs promise transport timeouts in the runtime options, and leave out what adapters actually get


**Severity:** Low. A custom adapter author who reads timeouts from the third argument gets none, and has no documented way to recognize a revalidation before returning `{:not_modified, origin}`.

**Doc:** `image_pipe/lib/image_pipe/source.ex:164-166` (also the comment at `source.ex:174-176`)
**Code:** `image_pipe/lib/image_pipe/source.ex:177-194,476-478`, `image_pipe/lib/image_pipe/config.ex:63-401`

**Evidence:** The callback doc says "The third argument holds runtime limits: `:max_body_bytes`, the transport timeouts, and the telemetry prefix." `runtime_opts/1` takes `:receive_timeout`, `:connect_timeout`, and `:pool_timeout` from the configuration, but `ImagePipe.config/1` has no such options, and `known_options!/1` rejects them. A runtime check of a custom adapter's `fetch/3` showed the keys `[:clock, :telemetry_prefix, :max_body_bytes]`. On a revalidation, `with_revalidated/4` also adds `:source_validation` (the previous `ImagePipe.Source.Origin`). A `{:not_modified, _}` returned without it fails with `{:source, :unexpected_not_modified}` (`source.ex:438-448`), which answers `502`. Neither `:clock` nor `:source_validation` is documented.

**Suggested wording:** "The third argument holds `:max_body_bytes`, `:telemetry_prefix`, and `:clock`, a function that returns the current Unix time in seconds. When ImagePipe revalidates an original, it also holds `:source_validation`, the `ImagePipe.Source.Origin` the adapter returned before. Return `{:not_modified, origin}` only then." Also correct the internal comment at `source.ex:174-176`.


### 36. `ImagePipe.Source.Path` suggests adapters see the custom scheme


**Severity:** Low. An adapter that matches on `scheme` to tell `blob://42` from `blobs/42` never matches.

**Doc:** `image_pipe/lib/image_pipe/source/path.ex:5-7`
**Code:** `image_pipe/lib/image_pipe/source/routes.ex:71-76`

**Evidence:** The moduledoc says "`scheme` is set when the path was written with a custom scheme (`asset://catalog/42`) ... It is `nil` for bare paths." `Routes.route/2` passes `%{source | scheme: nil}` to the adapter, so `resolve/3` always gets `scheme: nil`. The `resolve/3` callback doc (`source.ex:138-140`) correctly says the custom scheme is removed, so the two module docs disagree. The callback doc matches the code.

**Suggested wording:** "Root-relative path source. Its `segments` are the path after the source's matching prefix or custom scheme, so `media/photos/beach.jpg` and `media://photos/beach.jpg` both reach the adapter as `[\"photos\", \"beach.jpg\"]`."


### 37. `sources.md` says every adapter takes the cache settings, but S3 takes them per bucket


**Severity:** Low. `options: [default: [...], stable: :immutable]` raises `ArgumentError`. It fails loudly, but the doc points the reader at the wrong place.

**Doc:** `image_pipe/docs/sources.md:107-108`
**Code:** `image_pipe/lib/image_pipe/source/s3.ex:117-143` (top-level schema: `:default` and `:buckets` only), `s3.ex:34-115` (bucket settings include `CacheSettings.schema()`)

**Evidence:** "Every adapter also takes the cache settings in `ImagePipe.Source.CacheSettings`". For S3 they are bucket settings. A runtime check of `options: [default: s3default, stable: :immutable]` raised `invalid source :media: unknown options [:stable], valid options are: [:default, :buckets]`. The S3 moduledoc's "Bucket settings" section lists them correctly.

**Suggested wording:** "Every adapter also takes the cache settings in `ImagePipe.Source.CacheSettings`, explained in [Caching and freshness](caching-and-freshness.md). An S3 source takes them in `default:` or a bucket's settings."


### 38. `sources.md` doesn't list the duplicate `root_id` configuration error


**Severity:** Low. The paragraph reads as the full list of routing-level failures, and this one is missing.

**Doc:** `image_pipe/docs/sources.md:92-96`
**Code:** `image_pipe/lib/image_pipe/source/routes.ex:95-117`

**Evidence:** The doc lists failures for duplicate prefixes or schemes, more than one `path` source, and unsupported matches. `Routes.validate/1` also fails when two File sources share a `root_id` with different `root`s. A runtime check raised `invalid sources: root_id "x" names more than one directory`. The `root_id` option doc in `ImagePipe.Source.File` mentions it ("must have the same `:root`"), but the routing page doesn't.

**Suggested wording:** Add to the paragraph: "It also fails when two file sources have the same `root_id` but different `root` directories."


### 39. Redirects to another host keep custom auth headers, which the HTTP guide doesn't mention


**Severity:** Low. The guide's own example sends an `x-api-key` header and follows redirects to a second host. That key reaches the second host, while `auth:` and `authorization` don't.

**Doc:** `image_pipe/docs/serving-from-http.md:98-166`
**Code:** `image_pipe/lib/image_pipe/source/req_stream.ex:421-442`

**Evidence:** On a redirect to a different scheme, host, or port, `redirect_options/2` drops Req's `:auth` and `:aws_sigv4` and only the `authorization`, `proxy-authorization`, and `cookie` headers. Other headers from `req_options`, such as the guide's `{"x-api-key", ...}`, are sent to the redirect target. The target must still be in `allowed_hosts`, so the exposure is limited to hosts the operator listed. Neither the guide nor the `:req_options` or `:max_redirects` docs in `ImagePipe.Source.HTTP` say which credentials survive a redirect.

**Suggested wording:** Under "Follow redirects": "A redirect to another host, port, or scheme drops `auth:` and the `authorization` and `cookie` headers. Other headers, such as `x-api-key`, are sent to every host the origin redirects to."

**Question for Håvard:** Is forwarding arbitrary `req_options` headers across hosts intended? If not, the code may want to drop all configured headers (or keep an allowlist) on a cross-origin redirect, and the doc should then say that instead.


### 40. The documentation overview leaves out two guides


**Severity:** Low. Readers who start from the overview can't find the SVG and autoquality-target guides, which ExDoc lists in the sidebar.

**Doc:** `image_pipe/docs/index.md:39-58`
**Code:** `image_pipe/mix.exs:38,40`

**Evidence:** The "Running ImagePipe" group in `mix.exs` includes `docs/serving-svg-images.md` and `docs/choosing-an-autoquality-target.md`. `index.md` has no link to either. Every other guide in `@guide_groups` appears in `index.md`.

**Suggested wording:** Add to "Running ImagePipe", in sidebar order:
"- [Serving SVG images](serving-svg-images.md): render SVG originals with the optional `image_pipe_svg` package." after the detection entry, and
"- [Choosing a quality target](choosing-an-autoquality-target.md): pick an `autoquality` target for your images." after the processing-controls entry.


## Telemetry, tracing, detection, and SVG

How this was checked: static reading at commit 6a87579, with small `mix run --no-start` checks where noted. Docs covered: `image_pipe/docs/telemetry.md`, `telemetry-events.md` (every event entry compared with its emitting call site: `Telemetry.span`/`execute`/`start_span` callers across `image_pipe/lib/**`, plus `Summary`, `Logger`, `Catalog`), `tracing.md` (vs `Trace.Handler` `@safe_keys`, `@ok_results`, `ReqStep`, `FinchHandler`, `Trace`), `cookbook/opentelemetry-jaeger.md` (config keys checked against the opentelemetry 1.7.0 SDK in `image_pipe/deps`), `enabling-detection.md`, `custom-detectors.md` (vs `ImagePipe.Transform.Detector`, `Composite`, `ImageVision.Face`/`Objects`, `Warmup`, `Crop`, `Focal`, `Processing.check_required`, and image_vision 0.4.0 in `fiddle/deps`), `serving-svg-images.md`, `image_pipe_svg/README.md`, the `ImagePipe.Telemetry` and `ImagePipe.Transform.Detector*` moduledocs and docs, and `image_pipe_svg/lib/**` with its `mix.exs`. Recent commits 1354270 and f082f24 (path cut at the source, `:source_url`) were checked against the docs they touched, and the docs follow them. Everything not listed below matched the code.

### 41. The custom-detector check shows a log line the default Logger doesn't write


**Severity:** Medium. A reader following the guide attaches the Logger as shown, never sees the promised line, and concludes the detector isn't running.

**Doc:** `image_pipe/docs/custom-detectors.md:128-139`
**Code:** `image_pipe/lib/image_pipe/telemetry/catalog.ex:133-144`, `image_pipe/lib/image_pipe/telemetry/logger.ex:56-60`

**Evidence:** The guide says to request a crop "with the default Logger attached (`ImagePipe.Telemetry.attach_default_logger/0`)" and that "The log shows whether the detector found regions: `[info] image_pipe transform detect: detected`". It then says "A warning with `error` means `detect/2` returned an error". Without `stages: true`, `Logger.attach/1` subscribes only to `Catalog.summary_events/2`. That list holds `[:request, :summary]`, `[:request, :exception]`, the sweep and eviction events, and the cache write failures. `[:transform, :detect, :stop]` isn't in it. Runtime check: `ImagePipe.Telemetry.Catalog.summary_events([:transform, :request], [:image_pipe])` returns only `[[:image_pipe, :request, :exception], [:image_pipe, :request, :summary]]`. With the zero-arity attach, the detection result appears only as `detect=detected` (or `detect=error`, at `:warning`) on the request's summary line. `enabling-detection.md:173-199` gets this right by using `stages: true`.

**Suggested wording:** "Then request a crop through `ImagePipe.Plug` with the default Logger attached with a line for each stage (`ImagePipe.Telemetry.attach_default_logger(stages: true)`), for example `/images/w=400/h=400/fit=cover/detect=car/src/street.jpg`. The log shows whether the detector found regions:" Keep the `[info] image_pipe transform detect: detected` example. Alternatively, keep `attach_default_logger/0` and say: "The request's log line has `detect=detected` when the detector found regions."


### 42. `ImagePipe.Error.tag/1` doesn't exist, and `:error` differs between the request and its stages


**Severity:** Medium. The reference names a function a reader can't call, and a handler written to match `:bad_status` on `[:request]` never matches.

**Doc:** `image_pipe/docs/telemetry-events.md:44-45`
**Code:** `image_pipe/lib/image_pipe/telemetry.ex:277-283`, `image_pipe/lib/image_pipe/plug/runner.ex:352-355`, `image_pipe/lib/image_pipe/source.ex:560-561`

**Evidence:** The doc says "`:error` (atom): the error category from `ImagePipe.Error.tag/1`, on failures." No `ImagePipe.Error` module exists (runtime check: `Code.ensure_loaded?(ImagePipe.Error)` is `false`). The value comes from the private `ImagePipe.Telemetry.error_tag/1`, which takes the leading atom of the failure reason. Each emitter passes it a different reason. The `[:request]` stop passes the whole request error, so a missing original gives `error: :source` (runtime check: `error_tag({:source, {:bad_status, 404}})` is `:source`). `[:source, :fetch]`, `[:source, :resolve]`, `[:source, :stage]` and `[:source, :fetch_decode]` pass the inner source reason, so the same failure gives `error: :bad_status` there. The `telemetry.md:29` example line shows `error=source`, which matches the code.

**Suggested wording:** "`:error` (atom): the error category, on failures. It's the first atom of the failure reason. On `[:request]` and the summary, a failed source is `:source`. The source events give the source's own category, such as `:bad_status`."

**Also:** `image_pipe/mix.exs:81` lists `"ImagePipe.Error.tag/1"` in `@internal_doc_references` (`skip_code_autolink_to`), which is why ExDoc never warned about the dead reference. Other entries there are stale too: `ImagePipe.Security.verify/3`, `ImagePipe.Source.S3.Credentials.fetch/3` (the function is `fetch/2`) and `ImagePipe.Source.S3.Credentials.validate/1` are named by no doc. Remove them along with the doc fix.


### 43. SVG watermark parsing isn't in `[:source, :svg_render]`, and SVG limits don't set `:limit` on `[:source, :fetch_decode]`


**Severity:** Low. A handler that counts SVG rejections by `:limit` on `[:source, :svg_render]` misses watermark rejections, and one that reads `:limit` from `[:source, :fetch_decode]` gets nothing for most SVG limits.

**Doc:** `image_pipe/docs/telemetry-events.md:419-422`, `:435-448`, `:391-392`
**Code:** `image_pipe/lib/image_pipe/decode/svg.ex:97-136`, `image_pipe/lib/image_pipe/processing.ex:326-333`, `image_pipe/lib/image_pipe/decode.ex:385-389`, `:407-408`

**Evidence:** The doc says the span "Wraps rendering an SVG: parsing it, estimating the rendering cost, and rendering it", for originals and for watermarks, and lists the failure limits `:svg_bytes`, `:svg_elements`, `:svg_entities`, `:svg_text`, `:svg_nesting`, and `:pixels` for both. For an original, `decode/3` wraps `read`, `parse`, the cost check and the draw in the span, so the doc holds. For a watermark, `ImagePipe.Decode.SVG.watermark/2` runs `read` and `parse` outside any span, from `Processing.decode_watermarks/2`. Only `render_watermark/6` opens `[:source, :svg_render]` with `asset: :watermark`, around the cost check and the draw. So a watermark span never reports `:decode`, `:svg_bytes`, `:svg_elements`, `:svg_entities`, `:svg_text`, `:svg_nesting`, or an embedded image over `max_input_pixels`. Those failures show only as the `[:transform, :execute]` stop's `error: :input_limit` or `:decode`. Separately, `[:source, :fetch_decode]` documents "`:limit` (`:pixels` or `:frames`): with `:input_limit`, the limit that rejected the original". `error_stop_metadata/1` sets `:limit` only for `:too_many_input_frames` and `:too_many_input_pixels`. An SVG original rejected by any SVG-specific limit falls to the generic clause, `%{result: :processing_error, error: :input_limit}`, with no `:limit`.

**Suggested wording:** Under `[:source, :svg_render]`: "Span. Wraps rendering an SVG at the size the request needs. An SVG original renders during `[:source, :fetch_decode]`, and the span includes reading and parsing it. An SVG watermark renders during `[:transform, :execute]`, and the span covers only estimating the cost and rendering. A watermark that fails to parse, or crosses `max_bytes`, `max_input_pixels`, or a parse limit, emits no `[:source, :svg_render]` event." Under `[:source, :fetch_decode]`, `:limit`: "with `:input_limit`, the limit that rejected the original: `:pixels` or `:frames`. For an SVG's own limits, see `[:source, :svg_render]`."

**Question for Håvard:** should the watermark span move out to wrap `watermark/2`'s parse too, so both assets report the same limits? If so, the doc is right and the code would change.


### 44. `:materialize_error` isn't always a `415`


**Severity:** Low. An operator who sees `:materialize_error` with a `422` response reads it as a contradiction.

**Doc:** `image_pipe/docs/telemetry-events.md:741-742`
**Code:** `image_pipe/lib/image_pipe/transform/materializer.ex:27-33`, `:57-58`, `image_pipe/lib/image_pipe/response/error_status.ex:66`

**Evidence:** The doc says "`:result` (atom): `:ok`, or `:materialize_error` when the copy failed (the response is `415`)." Both `materialize/1` and `flush/1` report `:materialize_error` for any failure, including `WorkLimits.check/1`'s intermediate pixel limit. `error/1` maps that reason to `{:transform, {:intermediate_pixel_limit, _, _}}`, which `ErrorStatus.classify/1` answers with `422`. Only the copy or flush failures become `{:decode, _}` and `415`.

**Suggested wording:** "`:result` (atom): `:ok`, or `:materialize_error` when the image couldn't be computed. The response is `415` when the copy failed, or `422` when the image is over `max_intermediate_pixels`."


### 45. `[:cache, :stage]` never carries `output_format: nil`


**Severity:** Low. A handler that pattern-matches `%{output_format: nil}` never matches.

**Doc:** `image_pipe/docs/telemetry-events.md:561-562`
**Code:** `image_pipe/lib/image_pipe/telemetry.ex:466-475`, `:530-534`, `image_pipe/lib/image_pipe/cache/publication.ex:205-213`

**Evidence:** The doc says "`:output_format` (atom), or `nil` for an original or a body that isn't an image, such as a BlurHash." The emitters do pass `output_format: nil`, for example `publication.ex:212`. But `Telemetry.execute/4` runs `clean_metadata/1`, which drops every `nil` value. The page's own "Common metadata" section also says "A key whose value would be `nil` is left out of the metadata."

**Suggested wording:** "`:output_format` (atom): the stored format. Absent for an original or a body that isn't an image, such as a BlurHash."


### 46. `[:debug, :collect, :error]` always has `error: :error`


**Severity:** Low. The doc promises an error category that the event never carries.

**Doc:** `image_pipe/docs/telemetry-events.md:1023`
**Code:** `image_pipe/lib/image_pipe/decode.ex:664-671`, `image_pipe/lib/image_pipe/telemetry.ex:280-283`

**Evidence:** The doc says "Metadata: `:error` (atom), the error category." The event is emitted from a `rescue` with `error: Telemetry.error_tag(exception)`. `error_tag/1` only reads tagged tuples and atoms, so an exception struct falls to `error_tag(_reason) -> :error`. Runtime check: `ImagePipe.Telemetry.error_tag(%RuntimeError{message: "x"})` is `:error`. The default Logger then always writes `image_pipe debug collect: error (error)`.

**Suggested wording:** "Metadata: `:error` (atom), always `:error`." Or, if the exception type is wanted:

**Question for Håvard:** should the event carry the exception's module (for example `error: RuntimeError`) instead? That would make the current doc text accurate.


### 47. The blend event's face point isn't area-weighted


**Severity:** Low. This contradicts the content-aware cropping page.

**Doc:** `image_pipe/docs/telemetry-events.md:820`
**Code:** `image_pipe/lib/image_pipe/transform/focal.ex:38-43`

**Evidence:** The doc says "`:face` (`{x, y}`): the area-weighted center of the faces." `Focal.region_pull/2` weights each box by the square root of its area (`area_term(w, h) = :math.sqrt(w * h)`). `content-aware-gravity.md:37-52` says a larger box pulls "not in proportion to its area" and gives `pullᵢ = classWeight(labelᵢ) · √areaᵢ`, which matches the code.

**Suggested wording:** "`:face` (`{x, y}`): the center of the faces, each weighted by the square root of its area, as in [content-aware cropping](content-aware-gravity.md)."


### 48. Default Logger lines that appear only with `stages: true` are described as always logged


**Severity:** Low. A reader expects lines that never appear, and doesn't expect one that does.

**Doc:** `image_pipe/docs/telemetry-events.md:224-226`; `image_pipe/lib/image_pipe/telemetry.ex:87-104` (the `attach_default_logger/1` "Event groups" doc) and `image_pipe/docs/telemetry.md:24-55`
**Code:** `image_pipe/lib/image_pipe/telemetry/catalog.ex:127-144`

**Evidence:**
- `[:request, :ignored_options]` says "The default Logger logs it at its base level, as `image_pipe request ignored options: ok (fit, enlarge)`." It isn't in `summary_events/2`, so that line is written only with `stages: true`. Without stages, the options appear as `ignored=fit,enlarge` on the summary line. Other entries on the page say "with or without `stages: true`" when they mean it, which makes this omission read as "always".
- The `attach_default_logger/1` doc says "Without `stages: true`, only the `:request` group's summary and the `:cache` group's sweeps, evictions, and failed or dropped writes have lines". `summary_events/2` also subscribes to `[:request, :exception]`, "a request that raised (which has no summary)". So a request that raises logs `image_pipe request: exception (...)` instead of a summary line, and no doc says so. `telemetry.md` says "Each request then logs one line" without that case.
- The same doc's "Log levels" list says a summary logs at `:warning` for "detection whose detector failed, was unavailable, or isn't configured". `Logger.summary_warning?/1` (`logger.ex:216`) also warns for `detect=not_ready` (a required face model that isn't loaded yet). The stage list names cache coordination results "`:busy` and `:bypass`", but `level_for/3` (`logger.ex:187-188`) also warns for `:timeout`.

**Suggested wording:** In `[:request, :ignored_options]`: "With `stages: true`, the default Logger logs it at its base level, as `image_pipe request ignored options: ok (fit, enlarge)`. Without it, the summary line has `ignored=fit,enlarge`." In the `attach_default_logger/1` doc, add after the group sentence: "A request that raises has no summary, and logs its `[:request, :exception]` instead." In "Log levels", change to "detection whose detector failed, was unavailable, isn't configured, or isn't ready" and "cache coordination results `:busy`, `:bypass`, and `:timeout`".


### 49. The summary's `:reason` is missing on some failures


**Severity:** Low. A log search for `reason=` misses signature, expiry, and concealed-source failures.

**Doc:** `image_pipe/docs/telemetry-events.md:137-138`
**Code:** `image_pipe/lib/image_pipe/plug/errors.ex:29-60`

**Evidence:** The doc says "`:reason` (string): the message the error response's body gives, on failure. Plug requests only." `ImagePipe.Plug.Errors.send/2` calls `Summary.put(%{reason: ...})` only for `{:invalid_request, _}`, `{:invalid_source, _}`, `{:invalid_output, _}`, and the `ErrorStatus` fallback. The clauses for `:missing_signature` and `:invalid_signature` (`403`), `:signature_without_keys` (`400`), `:expired` (`410`), and `:invalid_concealed_source` (`404`) send a body but put no `:reason`. A `304`, `OPTIONS`, or `405` has none either, which is expected.

**Suggested wording:** "`:reason` (string): the message the error response's body gives, on failure. Plug requests only. Absent for a rejected signature, an expired URL, or a concealed source no key decrypts, whose responses don't explain the failure."


## Links, typespecs, HexDocs config, and architecture docs

How this was checked: commit 6a87579. Every relative markdown link and `#anchor` was resolved with a script, both on disk (GitHub view) and against ExDoc slugs (`ExDoc.Utils.text_to_id`, h2/h3 only, `module-` prefix in moduledocs). The scope was `image_pipe/docs/**`, `image_pipe_server/docs/**`, every README, `RELEASING.md`, `docs/index.md` and `docs/architecture/**`, plus the links inside `@moduledoc`/`@doc` in `image_pipe/lib`, `image_pipe_url/lib` and `image_pipe_svg/lib`. I built `mix docs` for `image_pipe`, `image_pipe_url` and `image_pipe_svg` into a scratch directory. All three built with no warnings. I then checked every `href`/`id` pair in the generated HTML, including the absolute `hexdocs.pm/image_pipe/...#...` links in `ImagePipe.Plan.Builder.Options`. Every backticked `ImagePipe*` module, function, `t:` and `c:` reference in those docs and moduledocs was checked for existence, arity and hidden status against `Code.fetch_docs/1` of the compiled modules. I compared `extras`, `groups_for_extras` and `groups_for_modules` in the three `mix.exs` files with the files and modules that exist. Typespecs were checked with dialyzer `-Wextra_return -Wmissing_return` over `image_pipe` and `image_pipe_url`. It reported only four functions, all in `@moduledoc false` modules (`ImagePipe.Decode.svg_config!/3`, `Delivery.Coordinator.progress_timeout/0`, `Plug.DiagnosticRenderer.render/2`, `Response.ErrorStatus.classify/1`). I also read the specs and typedocs of the public modules by hand: `ImagePipe`, `ImagePipe.URL`, `ImagePipe.URL.Config`, `Plan.Spec.Issue`, the `Source.*` value types, `CacheSettings`, `CachePolicy`, `Detector` and `Telemetry`. Apart from the items below, they matched the code. The architecture docs and `RELEASING.md` were read against the executor, step table, decode planner, mise tasks, scripts and workflows. The `RELEASING.md` steps, workflows, environment names, `IMAGE_PIPE_LIBS`, `@render_revision` and `release:hex --dry-run` all match. `fiddle.md` matches `mise.toml` and `fiddle/docker-compose.yml`.

### 50. Architecture docs link to `image_pipe/docs/api_contract.md`, which doesn't exist


**Severity:** Low. Three links in contributor docs are broken on GitHub.

**Doc:** `docs/architecture/execution_flow.md:38`, `docs/architecture/transform_operations.md:32`, `docs/architecture/transform_operations.md:74`
**Code:** the file is `docs/architecture/api_contract.md`. Its anchors `#processing-semantics` and `#pixel-effects` exist there.

**Evidence:** The links are `../../image_pipe/docs/api_contract.md`, `../../image_pipe/docs/api_contract.md#processing-semantics` and `../../image_pipe/docs/api_contract.md#pixel-effects`. `image_pipe/docs/` has no `api_contract.md`. The contract sits next to these files.

**Suggested wording:** Change the targets to `api_contract.md`, `api_contract.md#processing-semantics` and `api_contract.md#pixel-effects`.


### 51. Transform docs describe an `ImagePipe.Transform` behaviour and `Transform.run/3` that no longer exist


**Severity:** Medium (internal doc). A contributor adding an operation following this page would implement callbacks nothing calls and miss the step table, which AGENTS.md says every new operation needs.

**Doc:** `docs/architecture/transform_operations.md:12`, `:84-91`, `:114-115`, `:158`; `docs/architecture/execution_flow.md:66-68`
**Code:** `image_pipe/lib/image_pipe/transform/executor/step.ex:41-75` (`step/1` table, `random_access?/1`), `:91` (`run/4` with two defaults); `image_pipe/lib/image_pipe/transform.ex` (no `@callback`, no `run/3`)

**Evidence:** The doc says "Executable modules implement the `ImagePipe.Transform` behaviour: `name/1` ... `execute/2` ... `requires_materialization?/1` declares whether the operation needs random pixel access; the default is `false`." It also says "`ImagePipe.Transform.run/3` checks the operation's `requires_materialization?/1` callback." In the code, `ImagePipe.Transform` defines no callbacks and no `run` function. Operations are plain structs with `execute/2`. `ImagePipe.Transform.Executor.Step.step/1` gives each one its stage name, and `Step.random_access?/1` is the materialization policy. `Step.run/2-4` runs the operation inside the `[:transform, :operation]` span. No operation defines `name/1` or `requires_materialization?/1`.

**Suggested wording:** "Operations are typed parameter structs with an `execute/2` function over `ImagePipe.Transform.State`. The step table in `ImagePipe.Transform.Executor.Step` gives each one its stage name, the `:operation` of the `[:transform, :operation]` span. `Step.random_access?/1` lists the operations that run on a materialized image. A new operation adds a line to both. `Step.run/3` runs each operation with telemetry, the work limits, and materialization." Replace `ImagePipe.Transform.run/3` with `ImagePipe.Transform.Executor.Step.run/3` in `transform_operations.md:12, 114, 158` and `execution_flow.md:66`.


### 52. `Executor.decode_request/2` is now `Executor.decode_options/3`, and arbitrary rotations no longer disable shrink-on-load


**Severity:** Low (internal doc). The function name is wrong, and the described rotation behaviour is the opposite of the code.

**Doc:** `docs/architecture/execution_flow.md:41`; `docs/architecture/transform_operations.md:127-132`
**Code:** `image_pipe/lib/image_pipe/transform/executor.ex:80-107` (`decode_options/3`), `:202-215` (`decode_frame/2`), `:1198-1209` (`decode_terminal_reduction/2`)

**Evidence:** The docs name `ImagePipe.Transform.Executor.decode_request/2`, which doesn't exist. The planner entry point is `Executor.decode_options(spec, source_geometry, opts \\ [])`, which calls `DecodePlanner.open_options/5`. `transform_operations.md:129` says "An arbitrary-angle rotation disables shrink-on-load planning because resampling changes the crop frame." `decode_frame/2` gives an arbitrary angle the rotated bounding box with a headroom of 2, and the comment says "the decode can shrink before it, but the rotate then resamples near the output size: decoding at twice the target". So it still shrinks. The doc also says "BlurHash's terminal hint", but `decode_terminal_reduction/2` applies to both `:blurhash` and `:lqip_css`, and is also skipped when the group has pixel-sized effects or a trim. `api_contract.md:89` and its LQIP paragraph ("it adds no terminal-specific decode hint", around line 616) say the same and contradict the code the same way.

**Suggested wording:** `transform_operations.md:127-132`: "`ImagePipe.Transform.Executor.decode_options/3` derives the load shrink from the first group. Resize targets, crop extent, rotation, and a reducing terminal can contribute. A trim decodes at full size. An arbitrary-angle rotation plans against the rotated bounding box and decodes at twice the target, so the rotation's resampling stays sharp. The BlurHash and LQIP CSS reduction applies only to single-group requests without a trim or pixel-sized effects." Use the same name in `execution_flow.md:41`.

**Question for Håvard:** `api_contract.md` says LQIP CSS "adds no terminal-specific decode hint", but `decode_terminal_reduction/2` matches `terminal in [:blurhash, :lqip_css]`. Is the contract or the code the intended behaviour?


### 53. Architecture index names `Output.RequestPolicy` and a "trace Capture" that don't exist


**Severity:** Low (internal doc).

**Doc:** `docs/architecture/index.md:23`, `:45`
**Code:** `image_pipe/lib/image_pipe/output/policy.ex:101-103` (`ImagePipe.Output.Policy.from_request/3`); `image_pipe/lib/image_pipe/telemetry/catalog.ex`, `image_pipe/lib/image_pipe/telemetry/trace/handler.ex`

**Evidence:** "`Output.RequestPolicy` combines host defaults, request overrides, and Accept negotiation." No such module exists. `ImagePipe.Output.Policy.from_request/3` does this, and `execution_flow.md:15` already names `ImagePipe.Output.Policy`. "Telemetry changes update both the default Logger and trace Capture." No `Capture` module exists. The tracer is `ImagePipe.Telemetry.Trace.Handler`, and both it and the Logger subscribe from `ImagePipe.Telemetry.Catalog`.

**Suggested wording:** "`ImagePipe.Output.Policy.from_request/3` combines host defaults, request overrides, and Accept negotiation." And: "Telemetry changes update `ImagePipe.Telemetry.Catalog`, the default Logger, and the tracer (`ImagePipe.Telemetry.Trace.Handler`)."


### 54. Rotation range and orientation flushes in the transform doc are out of date


**Severity:** Low (internal doc).

**Doc:** `docs/architecture/transform_operations.md:60-62`, `:72`, `:117-118`
**Code:** `image_pipe_url/lib/image_pipe/api/option_spec.ex:769-775` (`parse_rotate/1` accepts any number); `image_pipe_url/lib/image_pipe/plan/angle.ex:17-22`; `image_pipe/lib/image_pipe/transform/executor.ex:361-375`; `image_pipe/lib/image_pipe/transform/executor/step.ex:67-77`

**Evidence:** The doc says "Rotation accepts clockwise angles in `[0, 360]`; parsing folds 360 to 0". The parser accepts any number, and `Angle.rotation/1` wraps it modulo 360 into `[0, 360)`. The user guide `image_pipe/docs/processing/crop.md:43-44` says this correctly ("`rotate=-90` is the same as `rotate=270`"). The doc says "Pixelate and gradient flush pending orientation". Progressive blur does too (`run_display_optional` at `executor.ex:363`). It also says "Smart or detector-guided crop and trim require this barrier", but `random_access?/1` also lists `Rotate`, `Blur`, `Sharpen`, `ProgressiveBlur` and `Pixelate`.

**Suggested wording:** "Rotation accepts any clockwise angle in degrees. Parsing wraps it into `[0, 360)`, so `-90` becomes `270`." "Progressive blur, pixelate, and gradient flush pending orientation..." "The operations `Step.random_access?/1` lists (arbitrary rotation, trim, blur, sharpen, progressive blur, pixelate, and smart or detect crops) run after this barrier."


### 55. `ImagePipe.PresetLookup` isn't in any HexDocs module group


**Severity:** Low. The behaviour shows up alone under an unnamed "Modules" heading at the top of the sidebar, apart from the other extension points.

**Doc:** `image_pipe/mix.exs:29-62` (`groups_for_modules`)
**Code:** `image_pipe/lib/image_pipe/preset_lookup.ex:1-2` (documented behaviour)

**Evidence:** In the generated `sidebar_items` it is the only `image_pipe` module with `"group":""`. Every other public module is grouped. The other `groups_for_modules` and `extras` entries in all three `mix.exs` files match existing files and documented modules. `image_pipe_svg` defines no groups, which is fine for three modules.

**Suggested wording:** Add `ImagePipe.PresetLookup` to the "Application API" group, or to a new "Extending" group with `ImagePipe.Source` and `ImagePipe.Transform.Detector`.


### 56. `S3 credentials` anchor in the server configuration reference is broken on HexDocs


**Severity:** Low. The link works on GitHub but not on HexDocs.

**Doc:** `image_pipe_server/docs/server-configuration.md:15` (`[S3 \`credentials\`](#s3-credentials)`)
**Code:** heading `#### S3 \`credentials\`` at `image_pipe_server/docs/server-configuration.md:263`. ExDoc adds ids only to h2 and h3 (`deps/ex_doc/lib/ex_doc/extras.ex:122`).

**Evidence:** The generated `server-configuration.html` has no `id="s3-credentials"`. The HTML anchor check flags it. The sibling `#### adapter = ...` headings have the same limit, but nothing links to them.

**Suggested wording:** Give the heading an explicit id, `#### S3 \`credentials\` {: #s3-credentials}`, or link to the `adapter = "s3"` section's parent `### [sources.<name>]` heading.


### 57. Public `Source.Response` docs point adapter authors at internal functions


**Severity:** Low. A custom-source author reads about `Source.with_fetched/3` and "`Source.fetch/3`" as if they were API, but both are `@doc false`.

**Doc:** `image_pipe/lib/image_pipe/source/response.ex:8`, `:20`
**Code:** `image_pipe/lib/image_pipe/source.ex:418` (`fetch/3`, `@doc false`), `:468` (`with_fetched/3`, `@doc false`)

**Evidence:** The moduledoc says "`Source.with_fetched/3` closes it even when no body is consumed." The `close/1` doc says "Releases a response obtained directly through Source.fetch/3." Neither function is documented, and the only public `fetch/3` is the `c:ImagePipe.Source.fetch/3` callback.

**Suggested wording:** Moduledoc: "ImagePipe calls `close` once it is done with the response, even when it reads no body." `close/1`: "Releases a response that your code fetched by calling an adapter's `c:ImagePipe.Source.fetch/3` directly."


### 58. Development page omits the SVG and audit checks


**Severity:** Low (contributor doc). A change to `image_pipe_svg/` isn't covered by any check the page lists.

**Doc:** `docs/architecture/development.md:16-24`
**Code:** `mise.toml:74-86` (`precommit:svg`), `:88-97` (`audit`), `:45-58` (`precommit` also runs `scripts/check-toolchain.sh`)

**Evidence:** The "Checks" list has `precommit`, `precommit:server`, `server:image` and `precommit:fiddle`. It doesn't list `mise run precommit:svg` (format, compile, credo, dialyzer, tests, `cargo fmt`, clippy, `cargo test` for `image_pipe_svg`), which `precommit` doesn't run. It doesn't list `mise run audit` either.

**Suggested wording:** Add "- `mise run precommit:svg` runs the `image_pipe_svg` checks, including `cargo fmt`, clippy, and the crate's tests." and "- `mise run audit` checks every lockfile for known vulnerabilities."


### 59. Root README leaves out `image_pipe_svg/` and promises design plans


**Severity:** Low.

**Doc:** `README.md:10-17`, `:19`
**Code:** `image_pipe_svg/` (sibling Mix project); `docs/index.md` (only "Architecture" and "Benchmark reports")

**Evidence:** The table "This repository holds sibling Mix projects" lists `image_pipe/`, `image_pipe_url/`, `image_pipe_server/` and `fiddle/`, but not `image_pipe_svg/`. "[Contributor notes](docs/index.md) cover architecture, design plans, and benchmarks", but `docs/index.md` has no design plans. They live on the `docs/design-docs` branch.

**Suggested wording:** Add a row: "| [`image_pipe_svg/`](image_pipe_svg/README.md) | Optional SVG source support, a precompiled resvg NIF released on its own |". Change the sentence to "[Contributor notes](docs/index.md) cover architecture and benchmarks."


### 60. API contract calls `detector` and `detector_required` mount options


**Severity:** Low (internal doc).

**Doc:** `docs/architecture/api_contract.md:254-255`
**Code:** `image_pipe/lib/image_pipe/config.ex:365-385` (`ImagePipe.config/1` schema); `image_pipe/lib/image_pipe/plug/config.ex:11-53` (mount options: `allow_origin`, `allow_debug_headers`, `http_cache`, `instance`, `mount`)

**Evidence:** "Mount options are `detector: :default | nil | module` and `detector_required: boolean`." Both are configuration options of `ImagePipe.config/1`. A mount with `:instance` rejects them, since it accepts only the mount options and `:mount` (`image_pipe/lib/image_pipe/plug.ex:39-43`).

**Suggested wording:** "Configuration options are `detector: :default | nil | module` and `detector_required: boolean`."


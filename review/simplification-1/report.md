# Simplification pass 1 (2026-10-06)

Scope: the whole repository (`image_pipe/`, `image_pipe_url/`, `image_pipe_server/`), looking for machinery, abstractions and architecture that can be removed or collapsed to reduce code surface. This includes leftovers from the old multi-dialect, compile-to-one-executor design, but is not limited to them. Report only: nothing in the code was changed.

Paths are relative to `image_pipe/lib/image_pipe/` unless they start with a project name. Line counts are approximate. Every "no caller" claim was checked with grep across `lib`, `test`, `bench`, `image_pipe_server` and `fiddle/lib`.

## Summary

| # | Opportunity | Win | Risk | Needs a decision |
|---|---|---|---|---|
| 1 | Replace the home-grown tracer and OTel replay with a live OTel handler | ~800 lib lines, 11 modules | High | Decided 2026-10-07: replace with live OTel handler |
| 2 | Drop the `ImagePipe.Cache` adapter behaviour (FileSystem is the only adapter) | ~250–300 lines | Medium | Decided 2026-10-07: remove; close whl3 and z3f.8 |
| 3 | Drop bounded-cache state persistence and warm start from peers | ~400 lines, 5 options, 3 events | Medium | Decided 2026-10-07: remove |
| 4 | Retire the `ImagePipe.Transform` behaviour and generic `run/3` dispatch | ~60–100 lines, one name vocabulary | Medium-high | Decided 2026-10-07: remove |
| 5 | Strip dead `summary`/`examples` metadata from `OptionSpec` | ~150 lines (up to ~450 if the table is reshaped) | Low | No |
| 6 | Merge Delivery Coordinator and Producer | ~300 lines, one process per request | High | Design note first |
| 7 | Remove test-only injection seams from production code | ~40–60 lines, one behaviour | Medium | No |
| 8 | Fold `Processing.Config` into `ImagePipe.Config` with NimbleOptions defaults | ~80–120 lines | Low-medium | No |
| 9 | Merge `Cache.OutputWork` into `Cache.Work` | ~150 lines | Medium-high | No |
| 10 | Collapse value-parsing wrappers in the URL layer | ~120–150 lines | Low | No |
| 11 | Shrink the bounded-cache tuning knobs | ~100 lines of schema/docs | Low-medium | Yes, public options |
| 12 | Move server-only modules out of `image_pipe_url` | Relocation; drops `mime` dep | Low-medium | No |
| 13 | Replace `DecodePlanner.Request` with a keyword result | ~50–70 lines | Medium | No |
| 14 | Stop passing request-scoped data through the `config` keyword | Clarity; ~20 lines | Medium | No |
| 15 | Simplify the watermark-inputs closure protocol | ~40–60 lines | Medium | No |
| 16 | One telemetry event catalog for the Logger and Capture | ~90 duplicated lines | Low-medium | No |
| 17 | `Plan.Color` struct model nothing needs | ~70 lines | Low-medium | No |
| 18 | Metric behaviour with one implementation, three namespaces | 2–3 modules, ~40 lines | Low | No |
| 19 | Padding and Monochrome wrapper operations; ExtendCanvas re-resolves its rule | ~60 lines | Low-medium | No |
| 20 | Executor crop branches and repeated materialize/error mapping | ~65 lines | Low | No |
| 21 | Shared prepare path for `Run` and `Plug.Runner` | ~30–40 lines | Low | No |
| 22 | URL parser key round trips and duplicated expand/settle/build | ~70–90 lines | Low-medium | No |
| 23 | Smaller collapses (identity, detector sentinel, enums, S3 opts, source cache settings, and more) | ~250 lines total | Low | No |
| 24 | Dead code | ~120 lines | Low | No |
| 25 | Dialect-era naming and comments | Wording only | Low | No |

Rough total if everything were done: 3,000–3,500 lines of lib code and a similar amount of test code. Findings 1–3 account for about half of that, and each removes or reshapes something a user can see.

### Overlap with existing beads

- **Finding 2 conflicts with `image_plug-whl3` ("Stabilize ImagePipe.Cache as a documented public behaviour") and `image_plug-z3f.8` ("Publish the cache adapter contract once stabilized").** Those beads plan to make the behaviour public; finding 2 suggests deleting it. Pick one direction.
- Finding 23 (identity material computed twice) touches the same code as `image_plug-e4a.8.14` ("Cache key and ETag hash the same material separately; represent runs 2-3x per request").
- Finding 3 touches the same code as `image_plug-e4a.8.15` (bounded cache startup scan) and `image_plug-i7n` (bounded cache overshoot on a shared root). Removing persistence doesn't fix either, but it shrinks the code they live in.
- `image_plug-9jb` ("Host preset lookup behaviour"): `ImagePipe.PresetLookup` already exists with one in-repo implementation. It's a real host extension point, so it's not listed here.

---

## 1. Replace the home-grown tracer and OTel replay with a live OpenTelemetry handler

**Win:** about 800 lib lines and 900+ test lines. Modules: `telemetry/trace/capture.ex` (398), `otel_replay.ex` (432), `otel_id_generator.ex` (56), `exporter.ex` (79), `log_exporter.ex` (43), `span.ex` (53), `stack.ex` (53), plus `id.ex`, `w3c.ex`, `inbound.ex`, `context.ex`, and the exporter paths in `req_step.ex` and `finch_capture.ex`.

**Risk:** high. It changes the public `attach_tracer(exporter:)` API, `docs/tracing.md` and `docs/cookbook/opentelemetry-jaeger.md`. Cross-process parenting through `ProcessingPool` (`processing_pool/events.ex`) needs re-verifying.

**Evidence:**
- Capture builds its own `%Span{}` records with its own IDs on a process-dictionary stack, then hands finished spans to an `Exporter` behaviour.
- Finished children arrive before their parents and the OTel SDK mints new span IDs. So `OtelReplay` (a GenServer) buffers spans per trace, waits for the root, and replays top-down with TTL sweeps and load shedding. `OtelIdGenerator` exists only to force ImagePipe's trace ID back into the SDK.
- The only real users are the server (`image_pipe_server/lib/image_pipe_server/application.ex:65`) and fiddle (`fiddle/lib/image_pipe_fiddle/application.ex:49`), both with `OpenTelemetryExporter`.
- `LogExporter` appears only in docs and its own test. Every other `Exporter` implementation is a test double.
- `OtelReplay` is started unconditionally in `application.ex:29` and wakes every 5 seconds even in hosts that never attach a tracer.

**Suggestion:** an OTel handler that starts a span on `:start` (`:otel_tracer.start_span` under the current `:otel_ctx`) and ends it on `:stop`/`:exception`. `Telemetry.RequestContext.capture/adopt` carries `:otel_ctx.get_current()` across process hops. Inbound `traceparent` and outbound injection in `ReqStep` use the OTel W3C propagator. This stays within AGENTS.md: optional dependency, public OTel API only, never attached automatically.

**Lower-risk middle option:** keep Capture, but have `OtelIdGenerator` also hand out ImagePipe's span IDs, so each span can be exported as soon as it ends under a synthetic parent context. This deletes only `OtelReplay` but requires hosts to configure the ID generator. Smallest step regardless: start `OtelReplay` from `attach_tracer` (or have the host supervise it) instead of in every host.

**Decision (Håvard, 2026-10-07):** do the full replacement with a live OTel handler; tracing without an OTel SDK (`LogExporter`, the custom `Exporter` behaviour) goes. Process hops keep going through `Telemetry.RequestContext`, whose `capture`/`adopt`/`within` carry the OTel context instead of the trace stack (plus a no-op branch when the optional OTel API isn't compiled in); `processing_pool/events.ex:13` reads `Stack.current()` directly and needs a rewrite. Request ID and trace ID are independent today and stay so; adding `request_id` to the root span's attribute allowlist would link them. Verify parenting across the pool and Producer hops first. Update the server, fiddle, `docs/tracing.md`, `docs/cookbook/opentelemetry-jaeger.md` and the Logger/Capture sync rule in AGENTS.md.

## 2. Drop the `ImagePipe.Cache` adapter behaviour

**Win:** about 250–300 lib lines in `cache.ex` and `cache/sink.ex`, plus three test adapters (171 lines) and the generic-adapter tests.

**Risk:** medium. The code change is low risk; the cost is test churn. 41 test files (209 references) use the probe adapters `CacheProbe` and `RaisingOpenCache`.

**Evidence:**
- The only `@behaviour ImagePipe.Cache` in lib is `cache/file_system.ex:37`. The other three are test support (`test/support/image_pipe/test/plug_fixture/cache_probe.ex`, `test/support/image_pipe/test/raising_open_cache.ex`, `test/support/image_pipe/request_safety_test/cache_probe.ex`).
- `ImagePipe.Cache` is `@moduledoc false`, and `docs/cache.md:5` documents only `{ImagePipe.Cache.FileSystem, options}`. `input_cache` already accepts only FileSystem (`cache/input.ex:16`); the server (`image_pipe_server/lib/image_pipe_server/config.ex:208`) and fiddle hard-wire it.
- `cache.ex` already special-cases FileSystem in `read_adapter` (line 284), `lookup_source_record` (line 147) and `startup_specs` (line 106).
- It uses callback-presence probes, which AGENTS.md forbids for trusted internal dispatch: `function_exported?` in `adapter_child_spec` (line 123), `missing_adapter_callbacks` (line 324), `normalize_adapter_options` (line 368).
- Entries are validated twice on a hit: FileSystem's `decode_entry`, then `Cache.validate_fetched_entry` runs `Entry.validate` again (`cache.ex:291`). `cache/entry.ex` handles `representation: nil`, which Sink never produces.

**Removable:** the `@callback`s, `@required_adapter_callbacks`, `validate_adapter`, `missing_adapter_callbacks`, `normalize_adapter_options`, the child-spec probe, the `fetch_entry` rescue and `invalid_adapter_result` branches, the shared/adapter option split (`cache.ex:40-56`, `349-375`), the non-FileSystem branch of `lookup_source_record`, about 80–100 of `cache/sink.ex`'s 312 lines (adapter fields, unexpected-result clauses), the second validation, and the `nil` representation clause in `Entry`.

**Suggestion:** `cache: [root: ...]` instead of `{module, opts}`, and `Cache` calls `FileSystem.Store` directly. Tests that need to see lookups and writes use a temp root, or the `[:cache, :lookup]`/`[:cache, :write]` events with a private `telemetry_prefix`.

**Fallback if the behaviour stays (per whl3/z3f.8):** delete the `function_exported?` probes and the `invalid_adapter_result` normalisation anyway, and skip the second `Entry.validate`.

**Decision (Håvard, 2026-10-07):** remove the behaviour and close `image_plug-whl3` and `image_plug-z3f.8`. If an S3 output cache comes later, design a new contract then from the FileSystem and S3 pair; the cache is `@moduledoc false`, so no host code depends on it today.

## 3. Drop bounded-cache state persistence and warm start from peers

**Win:** about 300 lines in `cache/file_system/admission.ex` (of 1,199), about 90 in `cache/file_system/sketch.ex`, 5 options, 3 telemetry events, a docs section, and around 1.8k lines of tests.

**Risk:** medium. This removes a documented feature: popularity counts would no longer survive a restart or carry across nodes. The startup scan would still rebuild sizes and enforce the cap.

**Evidence:**
- State file I/O in Admission: `admission.ex:152-290` (`load_own_state`, `load_peer_state`, `merge_peer_file`, `decode_state_payload`, `validate_state_payload`, `apply_own_state`), `993-1121` (`maybe_flush`, `terminate`, `serialize_state`, `cleanup_stale_peer_files`, `remove_own_state_temps`, `maybe_remove_stale_peer_file`, `remove_if_stale`), and `628-657` (`apply_protected_batch`, `persisted_protected_hashes`).
- A second `boot_cms` sketch exists only to carry loaded counts; it is summed in at `admission.ex:787` and aged at `901`.
- `sketch.ex:91-180`: `serialize`, `deserialize`, `sum`.
- Options `state_dir`, `flush_interval`, `cleanup_interval`, `state_ttl`, and `node_id` (which today only names the state file and the registry key `{root, node_id}`), in `cache/file_system/store.ex:74-175` and `image_pipe_server/docs/server-configuration.md`.
- Events `[:cache, :warm_start]`, `[:cache, :flush, :stop]`, `[:cache, :cleanup, :stop]` in `telemetry/logger.ex:43,63-64` and `telemetry/trace/capture.ex:41,56-57`.
- Docs: `docs/cache.md` "Warm start from peers".

**Suggestion:** keep W-TinyLFU in memory only; bounded mode then no longer needs `node_id`. Remove the three events from the Logger, Capture and `docs/telemetry-events.md` together.

**Decision (Håvard, 2026-10-07):** remove it. After a restart the cache still filters one-off requests (doorkeeper plus the strict admission gate, `policy.ex:119`) and re-protects entries on their first hit (`promote_on_hit`, `admission.ex:946`); the startup scan places existing entries in probation by file mtime (`admission.ex:326-337`), so until they are requested again eviction is oldest-written first. What is given up: keeping a popular-but-old entry before its next request, and a head start for new replicas. Bounded mode then no longer needs `node_id`.

## 4. Retire the `ImagePipe.Transform` behaviour and generic `run/3` dispatch

**Win:** about 60–100 lines: `transform.ex:30-97` (the `use` macro, three callbacks, `prepare`/`materialize`/`operation_result`), 21 `name/1` clauses, 4 `requires_materialization?/1` clauses and 21 `use ImagePipe.Transform` lines. It also removes one of two operation-name vocabularies.

**Risk:** medium-high. AGENTS.md describes `requires_materialization?/1` as the design, and the sequential-safety gate (`test/image_pipe/transform/sequential_access_test.exs`) plus about 40 tests drive operations through `Transform.run/3`. AGENTS.md, the gate and the `[:transform, :operation]` span must change together.

**Evidence:** this is the clearest compile-era leftover in the transform layer. The executor now owns a fixed stage order and builds every operation struct itself, but still dispatches through a generic "any operation module" contract.
- Only four operations need materialization: Rotate, Trim, ProgressiveBlur, and Crop with smart or detect gravity. The executor already knows this statically and calls `Crop.requires_materialization?/1` directly in three places (`transform/executor.ex:295`, `:412`, `transform/executor/geometry.ex:155`), going around the generic dispatch.
- `name/1` exists only to label the span, and its names differ from `Executor.operation_names/1` (`executor.ex:176`, `:854-891`): `:crop`/`:extend_canvas` versus `:crop_region`/`:crop_guided`/`:canvas`.
- Every operation struct is built only by `Executor` in production (Monochrome builds Duotone and Padding builds ExtendCanvas internally; see 19).

**Suggestion:** keep the operation structs as typed parameter data. Drop the behaviour and the `use` macro. The executor calls `Mod.execute(op, state)` through one private `run_stage(state, stage_name, op, materialize?)` that emits the span under the executor's own stage name, and decides materialization per stage. The gate test calls that helper (or a small public `Executor.run_operation/3`).

**Minimum if the gate makes this too costly:** delete `name/1` and take span names from the executor, so there is one name vocabulary.

**Decision (Håvard, 2026-10-07):** remove the behaviour. Start with a short note in `docs/plans/` (it spans the executor, the gate test, about 40 tests and the AGENTS.md sequential-safety rule). The gate keeps its strength by iterating the executor's stage table and requiring proof for every stage marked sequential-safe.

## 5. Strip dead `summary`/`examples` metadata from `OptionSpec`

**Win:** about 150 lines for the two fields alone (71 entries × 2 lines). Reshaping the table to one tuple per option takes `image_pipe_url/lib/image_pipe/api/option_spec.ex:112-682` (575 lines) down by roughly 450.

**Risk:** low.

**Evidence:**
- All 71 entries carry `summary:` and `examples:`. Nothing in lib, docs generation, fiddle or the server reads them. The only readers are `image_pipe_url/test/image_pipe/api/option_spec_test.exs:25-30` and one `hd(spec.examples)` at `image_pipe_url/test/image_pipe/api/parser_test.exs:942`.
- `name: nil` never occurs, yet `api/parser.ex:27` filters on `spec.name != nil`.

**Suggestion:** delete both fields and the test that polices them; use a literal in the parser test. Optionally turn the table into `{"w", :width, :group, &parse_dimension/1}` tuples with `fetch/1` backed by a compile-time map.

**Question for Håvard:** were `summary`/`examples` meant to feed a generated grammar reference? If so, that generator doesn't exist yet; if not, they are dead.

## 6. Merge the Delivery Coordinator and Producer

**Win:** about 300 lines. `delivery/coordinator.ex` (457), `delivery/producer.ex` (133) and the `delivery.ex` facade (106) could shrink to about 250. One fewer process and message hop per streamed chunk.

**Risk:** high. Cleanup-exactly-once, owner-death and Bandit abort invariants are subtle; `test/image_pipe/delivery/delivery_lifecycle_test.exs` and `producer_test.exs` pin them. Write a design note in `docs/plans/` first.

**Evidence:**
- The conn process starts a Coordinator GenServer, which monitors the owner, owns the cache sink and output lease, and spawns a linked Producer. The Producer runs `build_fun`/`pump` inside `ProcessingPool.within`. Every chunk crosses Producer → Coordinator → conn.
- The Producer already blocks in its own `receive` loop (`pump_loop`), so it could monitor the owner and write the sink itself.
- The comments still frame the build function as generic: "opaque `build_fun` (it knows nothing about decode/transform/encode)" (`coordinator.ex:5,18`), "the request runner that collects none" (`producer.ex:20-21`). There is one caller (`execution.ex:430`).
- `Delivery.stream/4` takes `conn_owner_pid`, and every caller passes `self()`.

**Suggestion:** fold the Coordinator's sink, owner-monitor and lease duties into the Producer and keep a thin `next`/`cancel` pull API on the conn side. Cheap first step: drop the always-`self()` parameter.

**Related:** `delivery/stream_pull.ex:56-112` (`resume/2` and its hand-rolled `Enumerable`) exists only to re-wrap a chunk that `Processing.produce_prepared` already pulled (`processing.ex:275`, `:388`), so the Producer can call `first_chunk` on it again. Have `pump` take `{first_chunk, stream_state}`, and have `produce_skipped` (`processing.ex:197-198`) call `first_chunk` itself. That deletes about 50 lines independently of the merge.

## 7. Remove test-only injection seams from production code

**Win:** about 40–60 production lines and one behaviour.

**Risk:** medium. About 15 test files use these seams to force failures. Each needs a real failing input instead (a corrupt image, a failing fixture source), or deleting.

**Evidence:** `test/image_pipe/plug_test.exs:254` calls these "test-injection seams, deliberately absent from every mount option surface":
- `:image_module`: `output/encoder.ex:73`, `output/clamp.ex:47,119,174`.
- `:image_open_module`: `decode.ex:446-458`.
- `:buffer_loader`: `decode.ex:469`.
- `:image_materializer`: `processing.ex:403`. `Transform.Materializer` declares `@callback materialize/2` and an arity-2 wrapper (`transform/materializer.ex:21,41`) with zero `@behaviour` implementers; they exist only for `FailingMaterializer` in `plug_test.exs:247`.
- `:output_capabilities`: `output/capabilities.ex:36-43`.
- `Detector.Composite`'s struct form (`new/1`, `default/0`, arity-2 functions): every caller is in test or test support.

**Suggestion:** this is the "callback wrappers" pattern AGENTS.md warns against. Start with the Materializer `@callback` and `materialize/2` (cheap), then retire the others one by one. Keep `:buffer_loader` only if the loader-allowlist tests have no other way to observe loader options.

## 8. Fold `Processing.Config` into `ImagePipe.Config` with NimbleOptions defaults

**Win:** about 80–120 lines, plus a workaround in the server.

**Risk:** low-medium.

**Evidence:**
- `processing/config.ex:11-31` keeps `@scalar_defaults`/`@map_defaults`, and `:319-395` applies them after validation (`resolve!`, `layer`, `range_check!`, `validate_quality_*`, `validate_target!`). `config.ex:24,46-47,191-199` concatenates the schema and calls `resolve!` afterwards.
- The schema docs hard-code "The default value is `80`" instead of using `default:`.
- `image_pipe_server/lib/image_pipe_server/config.ex:231-246` has to re-inject the defaults for the reference docs by calling `ImagePipe.Processing.Config.resolve!([])` ("The library applies these defaults after validation, so its schema doesn't carry them").
- Range checks are hand-rolled raises with an "invalid ImagePipe processing options" prefix, a leftover of processing options being a separate concept.

**Suggestion:** move the schema into `ImagePipe.Config`, use `default:` for scalars and `{:in, 1..100}` for quality, and keep only the struct merge for the map/encoder-option defaults. Delete `@scalar_defaults`, scalar `layer/2`, the manual range checks and the server re-injection.

## 9. Merge `Cache.OutputWork` into `Cache.Work`

**Win:** about 150 lines (`cache/output_work.ex` is 201).

**Risk:** medium-high. Concurrency, plus a lease transfer into `Delivery.Coordinator`.

**Evidence:**
- Both are node-local keyed single-flight GenServers with the same caps (`@max_keys 64`, `@max_waiters 1024`), caller monitoring, wait timeouts, a `:busy` fallback and coordination telemetry.
- Source acquisition already does "lock; on `:coalesced`, re-read the cache" (`execution/source_cache.ex:44-64`). Output uses a separate leader/waiter/result-broadcast protocol instead (`execution.ex:366-396`, `delivery/coordinator.ex:93,201,327,360`).
- The one thing `Work` lacks is a lease that outlives the calling function (`OutputWork.transfer/1`).

**Suggestion:** add `lock/unlock/transfer` to `Work`; the output path takes the lock and on `:coalesced` re-runs `Cache.lookup_entry`. Do this after 6 if both are picked, since both touch the Coordinator.

## 10. Collapse value-parsing wrappers in the URL layer

**Win:** about 120–150 lines.

**Risk:** low.

**Evidence:**
- `image_pipe_url/lib/image_pipe/api/option_spec.ex:1449-1545`: `parse_format_qualities`, `parse_autoquality`, `parse_max_bytes`, `parse_dpi`, `parse_{jpeg,png,webp,avif}_options` and `encoder_options` only map `API.OutputOptions`'s bare `:error` to `{:error, :invalid_x}`.
- `parse_dimension`/`parse_min_dimension` (`option_spec.ex:709-727`) unwrap `{:px, n}` from `API.Value.dimension`, which has no other caller.
- `api/output_options.ex:8-13` keeps an `@formats` map that duplicates `OptionSpec`'s `@format_map`.

**Suggestion:** have `API.OutputOptions`'s `parse_*` functions (lines 66-219) return the tagged reasons directly, or move them into `OptionSpec`, and delete the wrapper layer. Inline `Value.dimension`. Keep `API.OutputOptions` only for `serialize_encoder` and the encoder schema table, or fold those into `Serializer`.

## 11. Shrink the bounded-cache tuning knobs

**Win:** about 100 lines of schema and docs in `cache/file_system/store.ex:90-175`, the `@bounded_option_keys` list, `translate_to_admission_opts`, 9 server config keys and 18 rows in `image_pipe_server/docs/server-configuration.md:327-359`.

**Risk:** low-medium; these are public options.

**Evidence:**
- `window_ratio`, `sketch_depth`, `sketch_width`, `aging_sample_size`, `doorkeeper_cardinality`, `doorkeeper_fpr`, `eviction_victim_limit` and `reconcile_interval` all have derived defaults in `derive_bounded_options` (`store.ex:538-558`). No page under `image_pipe/docs` mentions them; the server re-exposes them (`image_pipe_server/lib/image_pipe_server/config.ex:216-217`).
- `Admission.init` (`admission.ex:97-126`) duplicates the defaults a second time "for direct-start unit tests".
- `store.ex:13-31` keeps `@option_keys`/`@bounded_option_keys` "in sync with @options_schema" by hand, and runs two validation passes (`560-578`) to emulate one `NimbleOptions.validate`. `translate_to_admission_opts` (`217-229`) renames seconds keys to `_ms` keys only for Admission.

**Suggestion:** keep `max_size_bytes` (and `node_id` if 3 isn't done); make the rest module constants derived from it. `Admission.init` uses `Keyword.fetch!`. Derive option keys from the schema, validate once, and let Admission read seconds directly.

**Question for Håvard:** were any of these knobs tuned in a real deployment or benchmark? If not, they're safe to hide.

## 12. Move server-only modules out of `image_pipe_url`

**Win:** relocation, not deletion. It shrinks the URL builder's public surface and drops the `mime` dependency.

**Risk:** low-medium. Public module names change, and both projects' architecture tests need updating.

**Evidence:**
- `ImagePipe.Format` (`image_pipe_url/lib/image_pipe/format.ex`, 144 lines) and `ImagePipe.Format.Detector` (155 lines): no `image_pipe_url` code calls them; only the Boundary `deps:` lines in `plan.ex:12` and `api.ex:9` mention them. Consumers are image_pipe's decode, cache and output modules and the server's config. `mime` is used only at `format.ex:88`.
- `Plan.Source.Path`, `.URL`, `.Object` and `.Identity` (about 85 lines) are produced and consumed only by image_pipe (`source/parser.ex`, `routes.ex`, `http.ex`, `s3.ex`, `file.ex`, `source.ex:509`). image_pipe_url uses only `Plan.Source.normalize/1`. AGENTS.md puts source identity under `ImagePipe.Source.*`, and their moduledoc ("Product-neutral source identifiers produced by parsers") is dialect-era wording.
- `API.DiagnosticRenderer` (175 lines) has one caller, `plug/errors.ex:21,42`. AGENTS.md puts error rendering under `ImagePipe.Plug`.

**Suggestion:** move `Format*` into image_pipe (for example `ImagePipe.Output.Format`/`ImagePipe.Decode.Format`), `Plan.Source.*` into `ImagePipe.Source.*`, and `DiagnosticRenderer` into `ImagePipe.Plug`. Then drop `mime` from image_pipe_url (AGENTS.md lists it as one of three allowed runtime deps).

## 13. Replace `DecodePlanner.Request` with a keyword result

**Win:** about 50–70 lines: `transform/decode_planner/request.ex` (49), `shrink_axes`/`request_net_quarter_turn?` and the default args and guards in `decode_planner.ex:38-90`, `exif_quarter_turn?/1` at `decode.ex:483`, and one Boundary export.

**Risk:** medium. Two planner test files (22 tests) need merging, and shrink math is golden-sensitive.

**Evidence:**
- `Executor.decode_request/2` (`executor.ex:61-75`) builds a struct that `Decode` immediately hands to `DecodePlanner.open_options_for/5` (`decode.ex:237-245`).
- `Decode` separately re-reads the EXIF orientation and passes `auto_rotate?` so the planner can XOR it with `user_quarter_turn?` to rediscover which frame the targets are in. The executor already knows: `decode_frame/2` returns `crop_frame`, the display dims rotated by the user angle, which is swapped exactly when that XOR holds.
- `Processing.Terminal` (`processing/terminal.ex:80`) compares two `decode_request` results for equality; that works equally well on the final keyword options.

**Suggestion:** one `Executor.decode_options(spec, geometry) :: keyword()` that passes `crop_extent || crop_frame` to a pure planner `load_option(format, extent, target)`. Delete `user_quarter_turn?`, the XOR, `exif_quarter_turn?/1`, the defaults and the guard clauses.

## 14. Stop passing request-scoped data through the `config` keyword

**Win:** about 20 lines, mostly clarity: `config` would hold only validated host configuration.

**Risk:** medium.

**Evidence:** at least ten per-request values are `Keyword.put` into config and read back elsewhere with `Keyword.get`:
- `execution.ex:404-407`: `:source_record`, `:output_lease`, `:watermark_inputs`; `execution.ex:476`: `:cost_us`, `:debug_info`.
- `processing.ex:312` (`{:started, await}`), `:342` (`:watermarks`), `:80` and `execution.ex:622` (`:classes`).
- `execution/source_cache.ex:50,114` (`:source_lease`), `plug/runner.ex:291-297` (`:debug?`), `plug/request.ex:54` (per-request `:presets`).
- Readers: `cache/sink.ex:40-64`, `cache.ex:172`, `delivery/coordinator.ex:93,201,327,360`.

**Suggestion:** pass the source record, output lease, cost and debug info explicitly to `Cache.open_sink` and `Delivery.stream`, and the watermark inputs as an argument to the build closure (see 15).

## 15. Simplify the watermark-inputs closure protocol

**Win:** about 40–60 lines.

**Risk:** medium; changes which fetch overlaps with what. Benchmark an uncached main source with a watermark before and after.

**Evidence:**
- Config `:watermark_inputs` holds one of three shapes: a map, `{:deferred, fn}` or `{:started, fn}` (`execution.ex:231-259`, `execution/watermarks.ex:82-91`, `processing.ex:303-345`). `Context.watermark_tasks` adds `[]`, a task list or `:deferred`.
- Watermark data passes through four shapes: a planned map `%{asset, source, opacity}` (`watermarks.ex:26`), `%Execution.Watermark{}`, an inputs map `%{asset => %{bytes, opacity}}` (`watermarks.ex:123`), and a decoded map `%{asset => %{image, opacity}}` (`processing.ex:337`).

**Suggestion:** pick one timing (always defer reads to the consuming process, or always await before `Delivery.stream`), which removes `watermark_tasks` and a branch. Make the planned entry a `%Watermark{}` from the start. Pass inputs as an explicit argument to `build_fun`/`Terminal.render`.

## 16. One telemetry event catalog for the Logger and Capture

**Win:** about 90 duplicated lines, and one AGENTS.md sync rule becomes enforced by code instead of review.

**Risk:** low-medium.

**Evidence:**
- `telemetry/logger.ex:11-88` (`@group_span_events` plus six one-shot lists) and `telemetry/trace/capture.ex:8-62` (`@span_stages`, `@oneshot_stages`) are maintained by hand. No test cross-checks them.
- They already differ: Capture traces `[:encode, :search, :probe, :encode]` and the two `:ssimulacra2` probe spans (`capture.ex:19-21`), which the Logger doesn't subscribe to. That may be intentional, but nothing records it.

**Suggestion:** one catalog in `ImagePipe.Telemetry`, e.g. `{stage, :span | :oneshot, group, log?: boolean}`, that both handlers derive their subscriptions from. If 1 is done, the Capture half becomes the OTel handler's subscription list.

## 17. `Plan.Color` struct model nothing needs

**Win:** about 70 lines in `image_pipe_url/lib/image_pipe/plan/color.ex`.

**Risk:** low-medium. Cache key data changes shape via `Color.key_data` (`output/policy.ex:123`), which is fine for a greenfield project.

**Evidence:**
- `space` is always `:srgb` and `alpha` is always `{:ratio, 1, 1}`. `with_alpha/2`, `valid?/1` and `to_rgba_list/1` have no lib callers; `rgba/4` is only called by `rgb/3`.
- The URL grammar, `Serializer` and the builder all use bare `{r, g, b}` tuples. `Plan.Builder.Values:125,225` builds a struct and immediately takes `.channels`.
- The struct survives only as `Output.Policy.flatten_background` (always `Color.white()`, see 24) and the trim background (`executor.ex:706` converts a tuple into the struct).

**Suggestion:** use `{r, g, b}` tuples throughout; keep `rgb_hex` and `rgb_name` as parse helpers. `image_plug-fmx` (explicit wide-gamut colours) and `image_plug-rj6` (CMYK target) would reintroduce a space; if either is near-term, keep the struct and only delete the dead functions.

## 18. Metric behaviour with one implementation, spread over three namespaces

**Win:** 2–3 modules, about 40 lines.

**Risk:** low.

**Evidence:**
- `output/metric.ex` declares `reference/score/leg_name` callbacks; `runtime/1` has one clause that returns `Metric.Ssimulacra2`.
- The crop path already hardcodes `Metric.Ssimulacra2.leg_name()` (`output/encode_search.ex:666`), and Capture hardcodes `[:encode, :search, :probe, :ssimulacra2, :metric]` (`capture.ex:21`).
- `encode_search.ex:625-660` passes the metric module around as a value only to call those three functions. `objective_of/1` and `crop?/2` match on `%ResolvedQualitySearch.Ssimulacra2{}` as if other objectives existed.
- One metric lives under three namespaces: `Output.Metric.Ssimulacra2`, `Output.ResolvedQualitySearch.Ssimulacra2` and `Output.Ssim2Metric.CropScore`.

**Suggestion:** delete `Output.Metric` and `runtime/1`, make the leg name a constant, and consolidate into one `Output.Ssimulacra2` module (reference, score, crop score, and possibly the resolved-search struct). Keep `EncodeSearch.search/3`'s closure injection; that's a real pure-core test seam.

## 19. Padding and Monochrome wrapper operations; ExtendCanvas re-resolves its rule

**Win:** about 60 lines: `transform/operation/padding.ex` (40), `transform/operation/monochrome.ex` (30) and the rule branch in ExtendCanvas.

**Risk:** low-medium. Span names `:padding`/`:monochrome` change unless the executor labels spans (see 4). The sequential gate's `%Padding{}`/`%Monochrome{}` cases go; ExtendCanvas and Duotone already cover them.

**Evidence:**
- `Padding.execute` (`padding.ex:25-39`) builds an ExtendCanvas with `{:dimensions, ...}` and a left/top anchor and calls `ExtendCanvas.execute`. `Monochrome.execute` builds a Duotone with a black shadow and calls `Duotone.execute`.
- `execute_canvas` (`executor.ex:427-452`) calls `ExtendCanvas.resolved_canvas_dims(rule, w, h)` for percentage offsets, then passes the rule on to ExtendCanvas, which recomputes the same dims (`extend_canvas.ex:107-108`). `resolved_canvas_dims` always returns `{:ok, _}`, and the executor hard-matches it (`executor.ex:434`), so its error path is dead.

**Suggestion:** ExtendCanvas takes resolved `width`/`height`; the canvas math moves to `Executor.Geometry`. The executor builds `%ExtendCanvas{}` for padding and `%Duotone{}` for monochrome directly. `Executor.operation_names` keeps the user-facing names.

## 20. Executor crop branches and repeated materialize/error mapping

**Win:** about 65 lines in `transform/executor.ex`, `transform.ex`, `operation/resize.ex` and `processing.ex`.

**Risk:** low; pure refactor covered by executor and golden tests.

**Evidence:**
- Guided crop (`executor.ex:266-347`) has five case arms. `{:identity, true}`, `{:none, true}` and `{_none_or_identity, false}` do the same thing, and `{:pending, true}` is equivalent to "flush, then rescale by the post-flush shrink", because `flush_display` → `orient_source_frame` (`executor.ex:618`) swaps `decode_shrink` just like `Geometry.orient_decode_shrink/2` (`executor/geometry.ex:133-137`). Region crop uses a `{:flush, state}` tagged-tuple hack (`maybe_flush_tagged/1`, `executor.ex:346`) for the same thing.
- "Materialize, then map the error to `{:decode, _}`" appears six times: `executor.ex:127-132` (public `Executor.materialize/1`, a pure alias), `:168-171`, `:900-906`, `transform.ex:85-93` (an internal `:materialize_error` tag round trip), `operation/resize.ex:58-62` (which leaks `{:materialize_error, _}` back into `Transform.run`) and `processing.ex:402-408`.
- The `Crop` struct's `aspect_ratio`/`enlarge` fields (`crop.ex:108-109,135-136`) are set only on a throwaway struct (`executor.ex:657-666`) built to call `Crop.resolved_box_dims/3`. The `resolved_box_dims(%{crop_from: %{}})` clause (`crop.ex:166`) has no caller, and `decode_crop_extent/2` (`executor.ex:825-828`) resolves the box twice.

**Suggestion:**
- Guided: if pending and not smart/detect, compensate and run; otherwise `flush_display` then run with `rescale_crop(crop, state.decode_shrink)`. Region always takes the second form. Delete `maybe_flush_tagged` and then `orient_decode_shrink`.
- `Materializer.materialize/1` and `flush/1` return `{:error, {:decode, reason}}` themselves. Delete `Executor.materialize/1` (Terminal calls Materializer directly), the `:materialize_error` tag and the `materialize_for_orientation_metadata` wrapper.
- Move the aspect-ratio box math into a pure `Executor.Geometry.crop_box/5` and drop the two Crop fields, the region clause and the double resolution.

## 21. Shared prepare path for `Run` and `Plug.Runner`

**Win:** about 30–40 lines and one forwarding function.

**Risk:** low.

**Evidence:**
- `run.ex:74-87` runs `Processing.prepare` → `Execution.watermark_sources` → `Source.from_input` → `Execution.prepare`, then `try … after Execution.close`. `plug/runner.ex:103-118` runs `Plug.Request.prepare` → `Source.resolve` → `Execution.prepare` with the same `try/after`.
- `Plug.Request.prepare/4` (`plug/request.ex:58-64`) is three forwarding calls inside a parse-focused module; its one lib caller is `runner.ex:107`.
- `report_ignored_options` is duplicated in `run.ex:89-95` and `plug/runner.ex:283-293`, and error metadata is built twice (`run.ex:199-206`, `plug/runner.ex:329-330`).
- `Run.validate/2` (`run.ex:124-130`) calls `Plan.built(plan)` twice.

**Suggestion:** one `Execution.start(request, source, accept, inputs, config)` (or `with_context/2`) that runs policy, watermarks, prepare and close; both entry points call it. Delete `Plug.Request.prepare/4` and share one ignored-options helper (the Plug adds only its debug header).

## 22. URL parser key round trips and duplicated expand/settle/build

**Win:** about 70–90 lines in `image_pipe_url/lib/image_pipe/api/parser.ex` and `plan.ex`.

**Risk:** low-medium.

**Evidence:**
- Clean maps are built keyed by URL key string (`parser.ex:297-331`), converted to intent names for `Presets.expand` (`typed_options`), back to URL keys (`url_options`, `:367-371`), and to names again for `Spec.settle` (`typed_groups`, `:518-534`). `@intent_keys`/`@url_keys` (`:27-29`) and `written?` (`:452-464`) support this.
- `parser.ex:46-62,436-450` and `plan.ex:178-196` both run `Presets.expand` → sort groups → `Spec.settle(…, written?)` → `%{Spec.build(groups, options) | ignored: warnings}`.
- `API.Presets.parse_fragment/1`, `references/1` and `compile_lookup/2` (`api/presets.ex:29-47`) only rename `Parser.parse_preset/1`, `Plan.Presets.references/1` and `Plan.Presets.compile/2`; the one caller is image_pipe's `presets.ex`.

**Suggestion:** key clean maps by `spec.name` at classification time (the occurrence keeps the URL key for spans, duplicates and `location_key`); this removes `url_options` and `@url_keys`. Add one `Spec.resolve/7` used by both Parser and Plan. Call `Parser` and `Plan.Presets` directly from `ImagePipe.Presets` and keep only `API.Presets.compile/2`.

## 23. Smaller collapses

Each is low risk and roughly 15–40 lines.

- **Identity material in three modules, computed twice for watermarked requests.** `execution/identity.ex` (136) builds `representation/identity_material.ex` (a 3-field struct) for `Representation.build/3`; `execution.ex:36-46,50-51,91-101` recomputes the whole thing inside `with_watermarks` only to replace `.representation`. AGENTS.md says `Representation` owns key composition, so move `Execution.Identity` into it and recompute only the representation part. Overlaps `image_plug-e4a.8.14`.
- **Detector `:default` sentinel resolved per request in six places.** `Transform.resolve_detector/1` and the wrappers `detector_available?`, `detector_ready?`, `detector_identity` (`transform.ex:101-131`) are called from `processing.ex:94,111,112`, `processing/config.ex:359`, `instance.ex:120,144`, `execution.ex:620`, `detector/warmup.ex:54`, `executor.ex:111`. Resolve `:default` to `Detector.Composite` once at config validation; `Detector.ready?/2` stays (real host boundary). Separately, detector classes are derived twice (`processing.ex:71-130`, `execution.ex:609-626`); compute them once during prepare.
- **Enum tables written in many places.** String↔atom maps in `OptionSpec` (`@fit_map`, `@anchor_map`, `@format_map`, `@output_map`, `@metadata_map`, `@color_profile_map`, `@hdr_map`, `:36-87`), special cases in `API.SerializedValue.scalar` (`:13-18`), atom lists in `Plan.Builder.Options` (`:8-19,295`) and `Plan.Builder.OutputOptions` (`:7-35`), and constants (`@max_axis`, gradient directions, detect weight limit, name regexes) duplicated between `OptionSpec:90-107` and `Plan.Builder.Values:7-8,18,36,287,297`. One bidirectional table per enum plus shared constants.
- **`API.URL` and `ImagePipe.URL` are one facade split in two.** `ImagePipe.API.URL` (195 lines) is called only from `ImagePipe.URL` (`url.ex:116`) but exported by the `API` boundary (`api.ex:10`). Fold it in as private functions, or at least stop exporting it.
- **S3 credential contract carries dead parameters.** `CredentialProvider.fetch_credentials/3`'s third argument is documented as "always `[]`" (`source/s3/credential_provider.ex:33`); `Credentials.fetch/3` ignores `runtime_opts` (`credentials.ex:28,32`); `RefreshCache.fetch/3`/`warm/3` take `opts` no lib caller passes (`refresh_cache.ex:37,47,59,74`). Make the callback `/2`, drop the unused `opts`, and drop RefreshCache's "generic, value-agnostic" framing (its only value type is S3 credentials). All four built-in providers are reachable from server config; keep them.
- **Source cache settings redundancy.** `internal_cache: :auto` and `:enabled` mean the same thing (`source/cache_settings.ex:117-122`), yet the server documents both (`image_pipe_server/docs/server-configuration.md:197,215,247`). `CacheSemantics.stable?` is fully determined by `byte_identity` (`source.ex:510-529` accepts only `{:strong, _}`+`true` or `:content`+`false`), so derive it. `CacheSettings.validate` is a `defdelegate` and `Source.CachePolicy.merge/2` is `Keyword.merge`; inline both.
- **Source records write a body nobody reads.** `Cache.remember_source` (`cache.ex:166-176`) writes `term_to_binary(record)` as a full body entry (with SHA-256 and fsync) and also puts the record in metadata. Reads only use metadata (`FileSystem.source_record/2` → `Store.metadata_hit`). Give Store a metadata-only put.
- **Delivery repackaging.** `delivery/coordinator.ex:296-303` replies with a map that `delivery.ex:82-93` copies into `%PreparedStream{}`, whose `headers` duplicates `resolved_output.response_headers` (read at `response/sender.ex:170-172`). `processing.ex:257-266` copies `Prepared` fields into a map for `DebugBuilder.build/1`, and `Prepared.operations` recomputes `Executor.operation_names(request)`, already computed at `processing.ex:279`.
- **Forwarders.** `Processing.streamable_source?` (`processing.ex:136`) → `Decode` `defdelegate` (`decode.ex:58`) → `Decode.Streaming.eligible?`, a double hop that exists only because the Execution boundary lacks a Decode dep (`execution/overlap.ex:123`). `error.ex` (13 lines, a top-level boundary with one `tag/1`) is used only for telemetry metadata; fold it into `ImagePipe.Telemetry`.
- **Encoder has two encode paths.** `lazy_output` (`output/encoder.ex:69-82`) and `buffer_for` (`:135-149`) branch on "no encoder tokens" between the `Image` wrapper and `VixImage.write_to_stream/buffer` with `vix_suffix`, which already handles `Q=` and the empty case. Always use the Vix path; compare output bytes first, since `Image.write`/`stream!` may add defaults (medium risk). This also removes `:image_module` from the encoder (see 7).
- **Orientation helpers.** `Orientation.swap_resize/1` (`transform/orientation.ex:113-121`) is a two-field swap with one caller (`executor.ex:401`); `Executor.Geometry.effective_dims/1` (`executor/geometry.ex:107-108`) aliases `State.effective_source_dims/1`; the quarter-turn swap of `source_dimensions`/`decode_shrink` exists in both `executor.ex:618-636` and `executor/geometry.ex:133-137`. Optionally fold `OrientationFlush` (69 lines) into `Materializer.flush`, its only production caller.
- **`RequestPolicy` is a one-caller builder.** `output/request_policy.ex` (171 lines) has one caller (`processing.ex:41`); it could become `Output.Policy.from_request/3`, removing a module and a Boundary export.
- **Visibility.** `Execution.finish/2` and `Execution.byte_identity/1` are public but called only within `execution.ex`; `Parser.message_for/1` (`image_pipe_url/lib/image_pipe/api/parser.ex:556-669`) is public with `@doc` but only called internally; `ImagePipeServer.Config.Tree.merge/2` is public `@doc false` but internal.
- **`Config.Reference` ships in the release.** `image_pipe_server/lib/image_pipe_server/config/reference.ex` (283 lines) only backs `mix image_pipe_server.gen.reference`; it could live in a dev-only compile path.

## 24. Dead code

Each verified with no non-definition callers in lib, server or fiddle.

- `response/discard.ex` (22 lines, a `Plug.Conn.Adapter`): referenced only by the Boundary export (`response.ex:20`) and `test/image_pipe/architecture_boundary_test.exs:316`.
- `Output.Policy.skip?/2` (`output/policy.ex:142-143`).
- `Output.Policy.flatten_background` / `Output.Resolved.flatten_background`: never set in lib, always `Color.white()` (`policy.ex:41`, `resolved.ex:19`), copied between them (`policy.ex:243`) and hashed into identity material (`policy.ex:123`). Only tests set it. Use white in `Encoder.flatten_for_format` and drop the field.
- `Executor.Geometry.display_live_dims/1` (`transform/executor/geometry.ex:115-118`).
- The `Crop.resolved_box_dims/3` region clause (`crop.ex:166`) and `ExtendCanvas.resolved_canvas_dims`'s `{:error, _}` path (see 19, 20).
- `Plan.Spec.errors/4` (`image_pipe_url/lib/image_pipe/plan/spec.ex:43-47`); `Spec.Validation.errors/4` is still used.
- `Plan.Color.with_alpha/2`, `valid?/1`, `to_rgba_list/1` (lib-dead; see 17). `rgba/4` is not dead: `rgb/3` calls it (`color.ex:31`).
- `ImagePipeServer.Config.Sources.options!/1` (`image_pipe_server/lib/image_pipe_server/config/sources.ex:75-86`): only its own test calls it.
- `Trace.Context.baggage` (`telemetry/trace/context.ex:9`) and `Span.links` (always `[]`); `OpenTelemetryExporter.available?/0` duplicates `ready?/0` and is referenced only in `docs/cookbook/opentelemetry-jaeger.md:83`.
- `attach_tracer`'s `function_exported?` and `Code.ensure_loaded?` probes (`telemetry.ex:200-209`), which AGENTS.md forbids for internal dispatch; the exporter also lives in both `persistent_term` (`Trace.set_exporter`) and Capture's handler config.
- `@removed_cache_option_keys [:key_headers, :key_cookies]` and `reject_removed_options` (`cache.ex:41,336-346`): a "was removed" migration shim in a greenfield repo, consumed only by `test/image_pipe/cache_test.exs:207`.
- `@core_execution_epoch 1` (`representation.ex:35,60-61`) next to `representation_schema: 1` and the ETag schema `"ipr1"`. AGENTS.md says not to bump internal key versions, so one marker (or none) is enough; `test/image_pipe/representation_test.exs:82` pins `core_epoch`.

## 25. Dialect-era naming and comments

Wording only, but they mislead readers into looking for other dialects, runners or build functions:

- "core" execution epoch (`representation.ex:35`), implying non-core dialects.
- "the request runner that collects none", "the request runner's image terminal" (`delivery.ex:2,60`, `delivery/producer.ex:20-21`); "The runner pulls the first chunk" (`delivery/stream_pull.ex:9-10`); "opaque `build_fun` (it knows nothing about decode/transform/encode)" (`delivery/coordinator.ex:5,18`).
- "preserving the chain's parse stop shape" and "compiled closure" (`plug/request.ex:39,45`).
- "invalid ImagePipe processing options" error prefix (`processing/config.ex:352,370,378,382,391`).
- "Product-neutral source identifiers produced by parsers" (`Plan.Source.*` moduledocs).
- The `delivery.ex` Boundary export comment ("The runner uses first_chunk/1 and resume/2").

---

## Checked and worth keeping

- `Execution.Acquisition` and `Processing.Prepared` look like 5-line leftovers but carry real hand-offs (source cache acquisition; prepare → produce across the overlap path).
- `PresetLookup`, `Source`, `Transform.Detector` and `Trace.Exporter` (if 1 isn't done) are real host extension points.
- `Instance.Publisher` (its `terminate` unpublishes config) and `ProcessingPool.Events` (keeps trace context per job).
- `Transform.Geometry`, `Executor.Geometry`, `SourceGeometry` and `Focal` don't duplicate each other.
- `Output.Skipped` vs `Output.Resolved`, and `Output.Negotiation`, are distinct result types and logic.
- `Source.CachePolicy`, `CacheSettings`, `CacheSemantics` and `CacheState` are separate layers apart from the redundancies in 23; `Response.CachePolicy` and `Source.CachePolicy` only share a name.
- `Diagnostic` vs `Spec.Issue` serve different surfaces (byte spans for 400 bodies vs builder locations).
- `URL.Helpers` and the `{:plan, plan}` serialize-and-reparse path for presets ("one grammar") are deliberate.
- The server's schema-driven `Config.Convert`/`Tree`/`Sources`/`TomlError` fit the "configured without Elixir code" design.
- The imgproxy `RotateAndFlip` orientation tables are a deliberate port.

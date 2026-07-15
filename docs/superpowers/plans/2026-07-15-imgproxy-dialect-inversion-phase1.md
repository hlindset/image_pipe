# imgproxy Dialect Inversion — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `ImagePipe.Dialect.Imgproxy` — a self-contained inverted Plug — alongside the untouched framework stack, driving the two shared extractions (`ImagePipe.Delivery`, `ImagePipe.Dialect.SharedConfig`), with the imgproxy wire + differential suites dual-running both stacks as the parity net.

**Spec:** `docs/superpowers/specs/2026-07-15-imgproxy-dialect-inversion-design.md` (commit `4e1ef049`). Every task below implements a spec section; when in doubt, the spec wins.

**Architecture:** The dialect owns its whole request chain (verify → parse → source → negotiate → representation → conditional → cache → fetch/decode brackets → inline per-pipeline geometry → deliver), calling core toolkit functions directly. Grammar modules are *copied* from `lib/image_pipe/parser/imgproxy/` (phase 2 retires the originals); `plan_builder.ex` + `resolver.ex` are *rewritten* as `Dialect.Imgproxy.Pipeline` with a pipeline-local carry. The worked example throughout is `lib/image_pipe/dialect/native/**`.

**Tech Stack:** Elixir, Plug, Vix/libvips, NimbleOptions, Boundary, ExUnit + StreamData.

## Global Constraints

- **Toolchain:** run every `mix` command as `export PATH="$(mise where elixir)/bin:$PATH" && mix …` (the Homebrew Elixir 1.19.3 shadow false-reds `mix dialyzer` on pre-existing framework specs). Fresh worktrees: `mise trust && mise exec -- mix deps.get` first.
- **Framework is observable-output-frozen.** The only sanctioned framework edits: Task 3's gated `SourceSession` migration, and test-helper normalization in Tasks 19–20. Nothing else under `lib/image_pipe/{request,plan,resolver,renderer,parser}/**` changes except where a task names the exact file.
- **No re-bake.** Never run `mix imgproxy.gen_fixtures` or `mix imgproxy.gen_sources`. A differential failure is a parity bug in the dialect, not a fixture problem.
- **Acid test:** `ImagePipe.Dialect.Imgproxy` depends only on core boundaries; no core module names it; it never names `ImagePipe.Dialect.Native`, `ImagePipe.Parser.*`, `ImagePipe.Request.*`, `ImagePipe.Resolver`, or `ImagePipe.Renderer`.
- **Telemetry tests:** every telemetry assertion uses a unique private `telemetry_prefix` (see AGENTS.md Test guidelines; existing example: `@clamp_telemetry_prefix` in `imgproxy_wire_conformance_test.exs`).
- **Subagents:** never run state-mutating git (`stash`, `reset`, `checkout -- .`); never read `deps/` source; run only the targeted tests your task names, not the full suite (the final task runs the full gates).
- **Copied-code duplication** is deliberate and transient: each copy task adds matching ignore entries to `.credo.exs` (ExDNA plugin) **and** the `mix ex_dna` invocation in `mise.toml` — both, or the two gates diverge (probe report §Final gates item 3).
- **Per-task gate** (every task, before its final commit): `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict` plus the task's own tests. Full `mise run precommit` runs only in Task 26.
- **Commit style:** end commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## Task overview (dependency order)

| # | Task | Spec section |
|---|---|---|
| 1 | D3 baseline characterization (shutdown + OTel parentage) + gate checkpoint | D3 in detail |
| 2 | Extraction A part 1: `ImagePipe.Delivery` core boundary (move from native) | Core changes §2 |
| 3 | Extraction A part 2 (GATED): `Request.SourceSession` migration | D3 in detail |
| 4 | Extraction B: `ImagePipe.Dialect.SharedConfig` + native `Config` migrates | Core changes §1 |
| 5 | G4: export `Transform.InputColorManagement`; `Lowering` comment update | Core changes §3–4 |
| 6 | Copy leaf request structs (`PipelineRequest`, `Effects`, `CropRequest`, `Orientation`, `Format`) | Module map |
| 7 | `Pipeline` part 1: per-pipeline skeleton (seed/carry/flush scoping) | Pipeline §1 |
| 8 | `Pipeline` part 2: carry math + marker-free padding/canvas | Pipeline §2, D5 |
| 9 | `Pipeline` part 3: 8-stage assembly + color preamble + decode preflight | Pipeline §3–4 |
| 10 | Copy grammar: `Signature`, `SourceEncryption`, `PercentEncoding`, `Presets` (+ dual-run tests) | Grammar copy-fidelity |
| 11 | `Dialect.Imgproxy.Request` (canonical struct, from `ParsedRequest`) | Architecture |
| 12 | Copy grammar: `OptionGrammar` + `Options` (+ dual-run tests, `parse_boolean` localized) | Grammar copy-fidelity |
| 13 | Copy grammar: `Path`, `Source`, `SourceScheme` (+ dual-run tests) | Grammar copy-fidelity |
| 14 | `Config` (three-way split) | Core changes §1 |
| 15 | `Identity` + `Negotiation` | Identity |
| 16 | `Errors` | Errors |
| 17 | The chain: `imgproxy.ex` image path + wire smoke tests | The visible chain |
| 18 | `/info/` endpoint + `InfoRenderer` + complete-body cache | The visible chain |
| 19 | Dual-run wire suite | Testing |
| 20 | Dual-run differential + per-arm cache isolation | Testing |
| 21 | Cross-arm raw body-hash equality | Testing |
| 22 | Contract kits (`CacheKey`, `RequestSafety`) | Testing |
| 23 | Orientation matrix incl. auto-rotate-OFF (G1) | Testing |
| 24 | Error-path matrix + mount/path semantics | Testing |
| 25 | Telemetry contract test (both arms) | Telemetry equivalence |
| 26 | Docs sync + architecture test + full gates + exit-criteria cross-check | Documentation sync, Exit criteria |

---

### Task 1: D3 baseline characterization + gate checkpoint

The two discoveries most able to invalidate downstream work are this gate and Task 7's skeleton — hence they run first. This task writes the **baseline tests green against the untouched supervised topology** (characterization-then-preserve, NOT red-green: the guarantees already exist). Task 3 must make the same *unmodified* tests pass post-migration; editing them to fit the new topology is a gate failure.

**Files:**
- Create: `test/image_pipe/request/delivery_shutdown_baseline_test.exs`
- Create: `test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs`
- Create: `.superpowers/sdd/d3-audit-report.md` (the audit finding, for the user checkpoint)

**Interfaces:**
- Consumes: `ImagePipe.Request.SourceSessionSupervisor.start_session/3`, `ImagePipe.Request.SourceSession.prepare/1` (existing framework API); the test helpers in `test/image_pipe/request/source_session_supervisor_test.exs` (`register_stream_events!/0`, `idle_owner!/0`, `request/1`, `opts/1`, `CleanupStreamImage` — reuse via the same pattern, copy the private helpers your tests need).
- Produces: two baseline test files that Task 3 must keep green **unmodified**, and an audit report that the user rules on.

- [ ] **Step 1: Read the prior art.** Read `test/image_pipe/request/source_session_supervisor_test.exs` in full (421 lines) — your baseline tests reuse its helper pattern. Read the spec's "D3 in detail" section.

- [ ] **Step 2: Write the two shutdown-related baselines — they have DIFFERENT fates, stated up front.**

The spec's preserve-unmodified gate applies only to tests that are
**topology-neutral** (they observe guarantees, not mechanisms). The app-tree
shutdown guarantee is mechanism-coupled *by nature* — it is a property of the
supervision tree itself — so a test of it structurally cannot survive the
supervisor's deletion. Pretending otherwise would smuggle the spec's named
failure mode ("editing the baseline to fit the new topology") in through the
back door. So:

- **Baseline A (owner-death cleanup) — topology-neutral, MUST survive Task 3
  unmodified.** Phrase it through the public surface: a spawned process runs a
  real framework request (`ImagePipe.Plug.call` with the wire suite's
  `RootHTTPAdapter`/`OriginImage` setup) against a multi-chunk origin; kill the
  owner process after the first chunk; assert cleanup fired **exactly once**,
  observed via the stream-lifecycle events `register_stream_events!/0` in
  `source_session_supervisor_test.exs` uses (read that helper for the exact
  event names and reuse the same mechanism — it is production instrumentation,
  not supervisor internals). No `SourceSession*` module is named anywhere in
  this test.
- **Baseline B (app-tree shutdown) — mechanism-coupled characterization,
  fate decided at the checkpoint.** This is the `start_supervised!` +
  `Supervisor.stop(infra, :shutdown)` test below. Mark its moduledoc: "This
  test characterizes the supervised topology's app-tree shutdown guarantee.
  It CANNOT survive the D3 migration unmodified. Its fate — deleted because
  the user ruled the app-tree arm out of contract, or kept because the user
  ruled it in contract (which selects the dialects-only branch, since the
  monitor topology structurally cannot preserve it) — is decided at the Task 1
  checkpoint and recorded in the audit report. Task 3 executes that ruling; it
  does not make it."

```elixir
defmodule ImagePipe.Request.DeliveryShutdownBaselineTest do
  @moduledoc """
  D3 topology-gate BASELINE (spec §D3 in detail, sequencing step 1).

  Characterizes the delivery-infrastructure shutdown guarantee as it exists
  on the supervised topology, BEFORE the SourceSession -> ImagePipe.Delivery
  migration. Task 3 must keep these tests passing UNMODIFIED; a changed
  assertion is a gate failure, not a passing gate.
  """
  use ExUnit.Case, async: false

  # Copy the private helpers (register_stream_events!/0, idle_owner!/0,
  # request/1, opts/1) and the CleanupStreamImage stub from
  # source_session_supervisor_test.exs verbatim — do not import across test
  # modules.

  # ── Baseline B — mechanism-coupled characterization (fate: checkpoint) ──
  test "app-tree shutdown terminates an in-flight prepared delivery, cleanup exactly once" do
    # Characterizes source_session_supervisor_test.exs:134's guarantee. This
    # test CANNOT survive the D3 migration; its fate is decided at the Task 1
    # checkpoint (see Step 2's fate note), never silently at Task 3.
    register_stream_events!()
    infra = start_supervised!({ImagePipe.Request.SourceSessionSupervisor, name: nil})

    {:ok, session} =
      ImagePipe.Request.SourceSessionSupervisor.start_session(
        infra,
        request(opts: opts(image_module: CleanupStreamImage)),
        owner: self()
      )

    session_ref = Process.monitor(session)
    assert {:ok, _prepared} = ImagePipe.Request.SourceSession.prepare(session)

    ExUnit.CaptureLog.capture_log(fn -> Supervisor.stop(infra, :shutdown) end)

    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}
    # cleanup exactly once: the stream-close event registered by
    # register_stream_events! fires exactly one time
    assert_receive {:stream_closed, _}
    refute_receive {:stream_closed, _}, 100
  end

  # ── Baseline A — topology-neutral, MUST survive Task 3 unmodified ──────
  test "owner death mid-stream cleans up exactly once (public-surface observation)" do
    # The guarantee that must survive the migration identically — it is the
    # only termination path the monitor topology has. Observed WITHOUT naming
    # any SourceSession* module: a real Plug request in a killed owner
    # process, cleanup observed via the stream-lifecycle events.
    register_stream_events!()

    owner =
      spawn(fn ->
        conn = Plug.Test.conn(:get, "/unsafe/rs:fit:64:64/plain/images/cat.jpg")
        ImagePipe.Plug.call(conn, ImagePipe.Plug.init(framework_opts_with_slow_origin()))
      end)

    owner_ref = Process.monitor(owner)
    # Wait for the stream-open event (delivery in flight), then kill the owner.
    assert_receive {:stream_opened, _}, 2_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

    assert_receive {:stream_closed, _}, 2_000
    refute_receive {:stream_closed, _}, 100
  end
end
```

(`framework_opts_with_slow_origin/0`: the wire suite's `RootHTTPAdapter` +
a chunk-gated origin stub — reuse `CleanupStreamImage`'s gating pattern from
`source_session_supervisor_test.exs`, served through the adapter. The event
names `{:stream_opened, _}`/`{:stream_closed, _}` are placeholders for
whatever `register_stream_events!/0` actually emits — read it and use its
real event shapes; the required semantics are: an in-flight signal to time
the kill, and an exactly-once cleanup signal.)

Adjust helper/message names to what `source_session_supervisor_test.exs` actually defines (`register_stream_events!` may emit differently-shaped messages — copy its real contract; the *assertions* above are the required semantics: DOWN + exactly-once cleanup).

- [ ] **Step 3: Run it.** `mix test test/image_pipe/request/delivery_shutdown_baseline_test.exs` — expected: **PASS** (characterization of existing behavior).

- [ ] **Step 4: Write the OTel parentage baseline.** Find the existing Capture test infra: `ls test/image_pipe/telemetry/` and read the trace-capture test file there. Write a test that drives one framework **cache-miss streamed image request** through `ImagePipe.Plug` (copy the request setup from `test/image_pipe/imgproxy_wire_conformance_test.exs` `@default_opts` + `call_imgproxy/3`, using a private `telemetry_prefix`), captures spans via the existing Capture harness, and asserts **semantic parentage only**: the `[:source]`/`[:transform, :execute]`/`[:encode]`-family spans (use the exact stage names Capture's `@span_stages` lists) are descendants of the `[:request]` span. Do **not** assert PIDs, span counts, or process structure (spec: "Assert semantics, not mechanism" — D3 *intends* to change topology).

- [ ] **Step 5: Run it.** `mix test test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs` — expected: **PASS**.

- [ ] **Step 6: Write the audit report** to `.superpowers/sdd/d3-audit-report.md`. It must present, with file:line evidence (already established in the spec's audit table — re-verify each): restart recovery absent (`restart: :temporary`, `source_session.ex:55`; pinned by `source_session_supervisor_test.exs:215`); no admission policy (`DynamicSupervisor.init(strategy: :one_for_one)`, no `max_children`); no host-visible API (no public docs; `docs/telemetry.md:860` is explanatory); PLUS the one finding requiring a ruling: **post-migration, nothing in `:image_plug`'s application tree supervises delivery processes, so `Application.stop(:image_plug)` alone (host conns still alive) no longer terminates in-flight deliveries — they terminate on owner death instead. The shipped native dialect already has exactly this property.** State the two gate outcomes (proceed / dialects-only) and recommend one.

- [ ] **Step 7: Commit and STOP for the user checkpoint.**

```bash
git add test/image_pipe/request/delivery_shutdown_baseline_test.exs \
        test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs \
        .superpowers/sdd/d3-audit-report.md
git commit -m "D3 gate: baseline shutdown + span-parentage characterization tests"
```

**⛔ CHECKPOINT: present the audit report to the user. Their ruling decides two things at once: (a) whether Task 3 runs at all, and (b) Baseline B's fate — ruled out of contract (test deleted at Task 3 with the ruling cited in the commit message) or in contract (which selects the dialects-only branch, since the monitor topology structurally cannot preserve the app-tree guarantee). Tasks 2 and 4–25 are unaffected either way; Task 26's exit-criterion 9 evidence records whichever outcome occurred.**

---

### Task 2: Extraction A part 1 — `ImagePipe.Delivery` core boundary

Move the probe's delivery lifecycle (`Native.Delivery` + `Coordinator` + `Producer`, ~700 lines) into a new top-level core boundary. Native consumes it directly; `Native.Delivery` is **deleted** (spec: a pass-through adapter fails the survival test). No framework change in this task.

**Files:**
- Create: `lib/image_pipe/delivery.ex` (from `lib/image_pipe/dialect/native/delivery.ex`)
- Create: `lib/image_pipe/delivery/coordinator.ex` (from `lib/image_pipe/dialect/native/delivery/coordinator.ex`)
- Create: `lib/image_pipe/delivery/producer.ex` (from `lib/image_pipe/dialect/native/delivery/producer.ex`)
- Delete: `lib/image_pipe/dialect/native/delivery.ex`, `lib/image_pipe/dialect/native/delivery/coordinator.ex`, `lib/image_pipe/dialect/native/delivery/producer.ex`
- Modify: `lib/image_pipe/dialect/native.ex` (alias `ImagePipe.Dialect.Native.Delivery` → `ImagePipe.Delivery`; add `ImagePipe.Delivery` to its Boundary `deps`)
- Modify: test files aliasing the old modules — find them: `grep -rl "Native.Delivery" test/` (known: `test/image_pipe/dialect/native_wire_test.exs` aliases `Native.Delivery.Coordinator`; `test/image_pipe/dialect/native_error_paths_test.exs`)
- Modify: `.credo.exs` + `mise.toml` — the ExDNA ignore entries for `native/delivery*` files point at the old paths; re-point them at `lib/image_pipe/delivery/*` (the duplication vs `Request.SourceSession` persists until Task 3 resolves it)

**Interfaces:**
- Produces: `ImagePipe.Delivery.stream(owner_pid :: pid(), build_fun :: (pump -> :done | {:error, term()}), representation :: ImagePipe.Representation.t(), response_meta :: ImagePipe.Plan.Response.t(), config :: keyword()) :: {:ok, ImagePipe.Response.PreparedStream.t()} | {:error, term()}` — the **same 5-arity signature `Native.Delivery.stream/5` has today** (`delivery.ex:79-89`); this task moves, it does not redesign. (Deliberate deviation from the spec's `stream(owner_pid, build_fun, opts)` sketch: `representation` and `response_meta` are load-bearing first-class arguments, not opts; the spec's `build_fun` contract itself is unchanged.) The `build_fun` contract is the spec's: arity-1 taking `pump`, calls `pump.(stream, content_type, resolved_output)` from inside the brackets, returns `:done | {:error, term}`.
- Consumed by: Task 3 (framework), Task 17 (imgproxy chain), native (immediately).

- [ ] **Step 1: Move the three files.** `git mv` each; rename modules `ImagePipe.Dialect.Native.Delivery{,.Coordinator,.Producer}` → `ImagePipe.Delivery{,.Coordinator,.Producer}`. In `delivery.ex` add the Boundary declaration:

```elixir
use Boundary,
  top_level?: true,
  deps: [
    ImagePipe.Cache,
    ImagePipe.Output,
    ImagePipe.Plan,
    ImagePipe.Representation,
    ImagePipe.Response,
    ImagePipe.Telemetry
  ],
  exports: []
```

(Start from the module's actual aliases; add `ImagePipe.Decode`/`ImagePipe.Source` only if the moved code references them — the brackets live in the *caller's* `build_fun`, so it likely does not. Let the Boundary compile error be the oracle; do not add unused deps.)

- [ ] **Step 2: Preserve the moduledoc caveats.** The Coordinator's moduledoc carries the G6 force-kill-backstop caveat and the monitor-direction invariant — verify both survive the move verbatim; the spec requires G6 "carries forward into the primitive's moduledoc".

- [ ] **Step 3: Update native.** In `lib/image_pipe/dialect/native.ex`: change the alias to `ImagePipe.Delivery` (call sites keep the name `Delivery`); add `ImagePipe.Delivery` to `deps:`. Update the test aliases found in Step 1's grep.

- [ ] **Step 4: Run the affected suites.**
`mix test test/image_pipe/dialect/` — expected: all native dialect tests PASS unchanged (the move is behavior-preserving).

- [ ] **Step 5: Gate + commit.**

```bash
mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict
git add -A
git commit -m "Extraction A pt1: move delivery lifecycle to core ImagePipe.Delivery

Native.Delivery/{Coordinator,Producer} move to a new top-level boundary;
native calls ImagePipe.Delivery.stream/5 directly (no adapter). Framework
untouched; SourceSession migration is Task 3, behind the D3 gate."
```

---

### Task 3: Extraction A part 2 (GATED) — `Request.SourceSession` migrates

**Runs only if the Task 1 checkpoint ruled "proceed".** If the ruling was dialects-only: create `.superpowers/sdd/d3-gate-outcome.md` recording the exact blocker, skip this task, and remove exit-criterion 9's framework arm from Task 26's checklist (the criterion's dialects-only branch applies instead).

**Files:**
- Modify: `lib/image_pipe/request/runner.ex` (session start goes through `ImagePipe.Delivery`)
- Delete: `lib/image_pipe/request/source_session.ex`, `lib/image_pipe/request/source_session/producer.ex`, `lib/image_pipe/request/source_session_supervisor.ex`
- Modify: `lib/application.ex` (remove the `ImagePipe.Request.SourceSessionSupervisor` child)
- Modify: `lib/image_pipe/request.ex` (Boundary: drop `SourceSessionSupervisor` export; add `ImagePipe.Delivery` dep)
- Modify: `docs/telemetry.md:860` (seam description: `SourceSession`/`Producer` → `ImagePipe.Delivery`)
- Delete: `test/image_pipe/request/source_session_supervisor_test.exs` — after porting its still-meaningful cases (owner-death, cancel, prepare-error) onto `ImagePipe.Delivery` in `test/image_pipe/delivery/delivery_lifecycle_test.exs`; the supervisor-specific cases (`assert_child_counts`, restart) die with their subject
- Modify: `test/image_pipe/request_runner_test.exs`, `test/image_pipe/architecture_boundary_test.exs` (references to the supervisor)
- Modify: `.credo.exs` + `mise.toml`: **remove** the ExDNA ignore entries for the `SourceSession`↔`Delivery` duplication — the duplication is now retired; the gates must prove it

**Interfaces:**
- Consumes: `ImagePipe.Delivery.stream/5` (Task 2). The framework's extra concerns (custom-render branch, detector identity) become `build_fun` variations built in `runner.ex` — read `runner.ex:150-220` first to map what the session start threads through today.
- Produces: a framework that streams through the same primitive the dialects use.

- [ ] **Step 1: Read** `lib/image_pipe/request/runner.ex` (full), `source_session.ex` (full), and the Task 1 baseline tests. Map every input `SourceSession.prepare/1` consumes onto `Delivery.stream/5`'s `build_fun`/opts.

- [ ] **Step 2: Migrate `runner.ex`.** Replace `SourceSessionSupervisor.start_session` + `SourceSession.prepare` with `ImagePipe.Delivery.stream(self(), build_fun, representation, response_meta, opts)` where `build_fun` wraps the existing `Processor` fetch/decode/encode flow exactly as native's `build_fun` does (`lib/image_pipe/dialect/native.ex:376-409` is the worked example). Preserve the runner's outward behavior: same `{:ok, {:prepared_stream, …}}` shapes to `Sender`, same error taxonomy.

- [ ] **Step 3: The topology-neutral baselines must pass unmodified.**
`mix test test/image_pipe/request/delivery_shutdown_baseline_test.exs test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs`
Expected: **Baseline A (owner-death) and the OTel parentage baseline PASS with zero edits** against the migrated runner. Baseline B (app-tree shutdown) is handled per the Task 1 checkpoint ruling recorded in `.superpowers/sdd/d3-audit-report.md`: ruled out of contract → delete Baseline B in Step 5 citing the ruling in the commit message; ruled in contract → **this task must not have started** (the dialects-only branch applies) — if you are here anyway, stop and revert. No third option exists; weakening any baseline assertion is a gate failure.

- [ ] **Step 4: Port the lifecycle tests.** Create `test/image_pipe/delivery/delivery_lifecycle_test.exs` porting owner-death, explicit-cancel, prepare-error, and double-stop-idempotence cases from `source_session_supervisor_test.exs` onto `ImagePipe.Delivery.stream/5`. Run: `mix test test/image_pipe/delivery/` — PASS.

- [ ] **Step 5: Delete** the three source files + supervisor child + supervisor test; update `request.ex` Boundary, `request_runner_test.exs`, `architecture_boundary_test.exs`, `docs/telemetry.md:860`; remove the ExDNA ignores.

- [ ] **Step 6: The framework still works.** Run the two heaviest framework consumers:
`mix test test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: PASS (the differential suite is the black-box proof the migration preserved output).

- [ ] **Step 7: Gate + commit** (same gate commands as Task 2).

```bash
git commit -m "Extraction A pt2: Request.SourceSession migrates onto ImagePipe.Delivery

D3 gate passed per .superpowers/sdd/d3-audit-report.md ruling. Supervisor,
its application.ex child, and its test retired; lifecycle cases ported;
baseline shutdown + parentage tests unmodified and green."
```

---

### Task 4: Extraction B — `ImagePipe.Dialect.SharedConfig`

**Files:**
- Create: `lib/image_pipe/dialect/shared_config.ex`
- Create: `test/image_pipe/dialect/shared_config_test.exs`
- Modify: `lib/image_pipe/dialect/native/config.ex` (delegate shared keys)
- Modify: `lib/image_pipe/dialect/native.ex` (Boundary deps + `ImagePipe.Dialect.SharedConfig`)

**Interfaces:**
- Produces:
  - `ImagePipe.Dialect.SharedConfig.keys() :: [atom()]` → `[:cache, :sources, :max_body_bytes, :max_input_pixels, :telemetry_prefix, :auto_avif, :auto_webp, :auto_jpeg_xl, :format_order]`
  - `ImagePipe.Dialect.SharedConfig.validate_runtime!(keyword()) :: keyword()` — delegates `:cache` → `ImagePipe.Cache.validate_config!/1`, `:sources` → `ImagePipe.Source.validate_config!/1`, validates the rest against the schema lifted from `Native.Config` (`config.ex:27-71`: `max_body_bytes`/`max_input_pixels` pos_integer with defaults 10_000_000/40_000_000, `telemetry_prefix` custom, `auto_*` booleans default true, `format_order` custom). Raises `ArgumentError` on invalid input. Pure data + validation — NOT a `use`-macro, NOT an orchestrator.
- Consumed by: `Native.Config` (now), Task 14's `Imgproxy.Config`.

- [ ] **Step 1: Write the failing test:**

```elixir
defmodule ImagePipe.Dialect.SharedConfigTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.SharedConfig

  test "keys/0 lists exactly the shared runtime keys" do
    assert Enum.sort(SharedConfig.keys()) ==
             Enum.sort([
               :cache, :sources, :max_body_bytes, :max_input_pixels,
               :telemetry_prefix, :auto_avif, :auto_webp, :auto_jpeg_xl, :format_order
             ])
  end

  test "validate_runtime!/1 applies defaults" do
    validated = SharedConfig.validate_runtime!([])
    assert validated[:max_body_bytes] == 10_000_000
    assert validated[:max_input_pixels] == 40_000_000
    assert validated[:auto_avif] == true
  end

  test "validate_runtime!/1 rejects invalid values" do
    assert_raise ArgumentError, ~r/max_body_bytes/, fn ->
      SharedConfig.validate_runtime!(max_body_bytes: -1)
    end
  end

  test "validate_runtime!/1 delegates cache and sources validation" do
    assert_raise ArgumentError, fn ->
      SharedConfig.validate_runtime!(cache: :not_a_cache_config)
    end
  end
end
```

- [ ] **Step 2:** `mix test test/image_pipe/dialect/shared_config_test.exs` — FAIL (module undefined).
- [ ] **Step 3: Implement** by lifting the schema entries and custom validators (`validate_telemetry_prefix`, `validate_format_order`) out of `Native.Config` into `SharedConfig`, with `use Boundary, top_level?: true, deps: [ImagePipe.Cache, ImagePipe.Source, ImagePipe.Format, ImagePipe.Telemetry], exports: []`. `Native.Config.validate!/1` becomes: split on `SharedConfig.keys()`, `SharedConfig.validate_runtime!(shared)`, validate its own dialect keys (`keys`, `presets`, `on_inert_option`, `storage_inputs`), merge.
- [ ] **Step 4:** `mix test test/image_pipe/dialect/` — PASS (SharedConfig tests + all native config/wire tests unchanged).
- [ ] **Step 5: Gate + commit:** `git commit -m "Extraction B: ImagePipe.Dialect.SharedConfig; native Config delegates shared keys"`

---

### Task 5: G4 — export `InputColorManagement`; update `Lowering`/`ResizePlanning` export comment

**Files:**
- Modify: `lib/image_pipe/transform.ex` (Boundary `exports:` list gains `InputColorManagement`; the comment above `Lowering, ResizePlanning` — currently "exported for the in-tree imgproxy strategy only" — becomes "exported for the in-tree imgproxy consumers (the framework strategy and the inverted dialect); not part of the strategy SDK and subject to change without notice")
- Test: none new — this is an export widening consumed by Task 9; the Boundary compile is the check.

- [ ] **Step 1:** Add `InputColorManagement` to the exports list in `lib/image_pipe/transform.ex` with a comment: `# Input color-management preamble — dialect-callable (spec G4); the framework's Executor seeds it internally.` Update the `Lowering`/`ResizePlanning` comment.
- [ ] **Step 2:** `mix compile --warnings-as-errors` — PASS.
- [ ] **Step 3: Gate + commit:** `git commit -m "Export Transform.InputColorManagement for dialect preambles (G4)"`

---

### Task 6: Copy leaf request structs

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy.ex` (the Boundary stub — see Interfaces)
- Create (copies): `lib/image_pipe/dialect/imgproxy/pipeline_request.ex`, `effects.ex`, `crop_request.ex`, `orientation.ex`, `format.ex` — from the same-named files under `lib/image_pipe/parser/imgproxy/`
- Modify: `.credo.exs` (ExDNA ignore entries for the five new files, justification "phase-1 dialect copy, retired in phase 2 per spec 2026-07-15") + the matching `--ignore` globs in `mise.toml`'s `mix ex_dna` line
- Test: `test/image_pipe/dialect/imgproxy/leaf_structs_test.exs`

**Interfaces:**
- Produces: `ImagePipe.Dialect.Imgproxy.PipelineRequest` (struct identical to `ImagePipe.Parser.Imgproxy.PipelineRequest` — all 37 fields, same defaults), `…Effects`, `…CropRequest`, `…Orientation`, `…Format`. These are the types Tasks 7–9 and 12 build on.
- **The Boundary stub lands NOW.** Boundary classifies modules by longest prefix, and `ImagePipe` itself is a boundary (`lib/image_pipe.ex`) whose dep list does not include `ImagePipe.Config`, `Representation`, `Output`, etc. — so without a declared `ImagePipe.Dialect.Imgproxy` boundary, every copied module is absorbed into the ROOT boundary and Tasks 12/14/15's per-task `compile --warnings-as-errors` gates fail on boundary diagnostics. Create `lib/image_pipe/dialect/imgproxy.ex` in THIS task as a stub carrying the full Boundary declaration (the exact `use Boundary` block from Task 17's Interfaces, minus the `exports: [SourceScheme]` — start `exports: []`; Task 13 adds the export when the module exists; Task 17 adds `@behaviour Plug` and the chain to this same file):

```elixir
defmodule ImagePipe.Dialect.Imgproxy do
  @moduledoc false
  # Boundary anchor for the dialect namespace; the Plug chain lands in Task 17.
  use Boundary,
    top_level?: true,
    deps: [...]   # Task 17's full list, verbatim
end
```

- [ ] **Step 1: Copy + rename.** For each file: `cp lib/image_pipe/parser/imgproxy/X.ex lib/image_pipe/dialect/imgproxy/X.ex`, then rename the module `ImagePipe.Parser.Imgproxy.*` → `ImagePipe.Dialect.Imgproxy.*` and every internal alias between the five (e.g. `PipelineRequest` aliases `CropRequest`, `Effects`, `Orientation`). `ImagePipe.Plan.Color` references stay (shared value type per the spec's Module map).
- [ ] **Step 2: Write the copy-fidelity test:**

```elixir
defmodule ImagePipe.Dialect.Imgproxy.LeafStructsTest do
  use ExUnit.Case, async: true

  test "PipelineRequest copy carries identical fields and defaults" do
    original = Map.from_struct(%ImagePipe.Parser.Imgproxy.PipelineRequest{})
    copy = Map.from_struct(%ImagePipe.Dialect.Imgproxy.PipelineRequest{})
    # Effects sub-structs differ by module name; compare shapes.
    assert Map.keys(original) == Map.keys(copy)
    assert Map.drop(original, [:effects, :orientation]) ==
             Map.drop(copy, [:effects, :orientation])
    assert Map.from_struct(original.effects) == Map.from_struct(copy.effects)
    assert Map.from_struct(original.orientation) == Map.from_struct(copy.orientation)
  end
end
```

- [ ] **Step 3:** `mix test test/image_pipe/dialect/imgproxy/leaf_structs_test.exs` — PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy: copy leaf request structs (phase-1 copy, spec D1)"`

---

### Task 7: `Pipeline` part 1 — the per-pipeline skeleton

**The second downstream-invalidating discovery.** imgproxy's `-` pipelines are NOT native's `then` groups (spec §Pipeline 1). The skeleton reproduces `Executor.execute_pipeline/4`'s scoping: per pipeline — re-seed `SourceShape`, fresh carry, flush boundary. Only the executed image/`State` crosses a pipeline boundary.

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/pipeline.ex`
- Test: `test/image_pipe/dialect/imgproxy/pipeline_scoping_test.exs`

**Interfaces:**
- Consumes: `ImagePipe.Dialect.Imgproxy.PipelineRequest` (Task 6); core: `Transform.{State, SourceShape, NeutralResolver, Chain, PendingOrientation, Operation.Flush}`, `Plan.Operation`.
- Produces:
  - `Pipeline.run(State.t(), SourceGeometry.t(), request, keyword()) :: {:ok, State.t()} | {:error, {:transform | :decode, term()}}` where `request` is any struct/map with a `pipelines :: [PipelineRequest.t()]` field (Task 11's `%Request{}` will be the real caller; tests may pass a bare map).
  - Internal seams (used by Tasks 8–9, private but defined here): `run_pipeline/3`, `run_op/6` (state, shape, carry, plan_op, pctx, ctx), `follow/5`, `flush_boundary/3`, `build_ctx/1` (with the same `:chain`/`:measure_dims`/`:continue` test-only injection seams native's `build_ctx` has, `native/pipeline.ex:166-173`).
  - The pipeline context: `%{mode: :resize | :canvas_preserving, dpr_fallback: float()}` derived per pipeline (Task 8 consumes it).

- [ ] **Step 1: Write the failing scoping tests.** These pin the boundary-crossing table from the spec before any geometry exists — use a minimal op set (a resize per pipeline) and the `:chain` injection seam to observe per-pipeline behavior without pixels:

```elixir
defmodule ImagePipe.Dialect.Imgproxy.PipelineScopingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.State

  # Build a State the way Decode.with_image seeds one (no real image needed
  # when :chain and :measure_dims are injected): see
  # test/image_pipe/dialect/native/ pipeline tests for the pattern of
  # constructing a State with source_dimensions + a stub image.

  test "SourceShape is re-seeded per pipeline from the prior pipeline's output dims" do
    # Two pipelines: p1 resizes to 400x300; p2's ops must be resolved against
    # a shape seeded at 400x300, NOT the original 1600x1200.
    # Inject :chain to record each executed op batch and return a State whose
    # effective_source_dims reflect the resize output; inject :measure_dims
    # to return the post-resize dims. Assert the second pipeline's eventual
    # crop/resize executables are parameterized against 400x300.
  end

  test "pending orientation is flushed at every pipeline boundary" do
    # State with a non-identity pending_orientation and TWO pipelines:
    # the recorded op batches must include a %Transform.Operation.Flush{}
    # at the END of pipeline 1 (not only after pipeline 2) — each pipeline
    # ends in the display frame (Executor.execute_pipeline/4 contract).
  end

  test "an empty request runs zero pipelines and returns the state unchanged" do
    # pipelines: [%PipelineRequest{}] (the singleton default) with no ops set
    # -> {:ok, state} with no chain calls (empty op assembly => no-op).
  end
end
```

Write these as real tests (the comment bodies above describe the required assertions; the implementer writes the arrange/act/assert code using the injection seams — the native pipeline tests under `test/image_pipe/dialect/native/` show the exact `State`/stub-image construction pattern to copy).

- [ ] **Step 2:** `mix test test/image_pipe/dialect/imgproxy/pipeline_scoping_test.exs` — FAIL (module undefined).

- [ ] **Step 3: Implement the skeleton:**

```elixir
defmodule ImagePipe.Dialect.Imgproxy.Pipeline do
  @moduledoc """
  Inline per-pipeline geometry for the imgproxy dialect.

  Scoping reproduces `ImagePipe.Transform.Executor.execute_pipeline/4`, NOT
  `ImagePipe.Dialect.Native.Pipeline` [spec §Pipeline 1]: imgproxy `-`
  pipelines each re-seed `SourceShape` from the prior pipeline's output,
  start a fresh carry, and flush pending orientation at their own boundary —
  a pipeline's output is the next pipeline's input, so each ends in the
  display frame. Only the executed image/`State` crosses a pipeline boundary.
  """

  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  @max_continuation_depth 4

  @empty_carry %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

  @spec run(State.t(), ImagePipe.Transform.SourceGeometry.t(), %{pipelines: [PipelineRequest.t()]}, keyword()) ::
          {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
  def run(%State{} = state, _geometry, %{pipelines: pipelines}, opts) do
    ctx = build_ctx(opts)

    Enum.reduce_while(pipelines, {:ok, state}, fn %PipelineRequest{} = preq, {:ok, state} ->
      case run_pipeline(state, preq, ctx) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Per-pipeline: fresh shape seed, fresh carry, own flush boundary.
  defp run_pipeline(%State{} = state, %PipelineRequest{} = preq, ctx) do
    {w, h} = State.effective_source_dims(state)

    shape =
      SourceShape.seed(%{
        width: w,
        height: h,
        pending_orientation: state.pending_orientation,
        decode_shrink: state.decode_shrink
      })

    pctx = pipeline_ctx(preq)

    with {:ok, state, shape, _carry} <-
           run_ops(state, shape, @empty_carry, operations(preq, shape), pctx, ctx) do
      flush_boundary(state, shape, ctx)
    end
  end

  # Task 8 fills the mode/dpr derivation; Task 9 fills operations/2.
  defp pipeline_ctx(%PipelineRequest{}), do: %{mode: :resize, dpr_fallback: 1.0}
  defp operations(%PipelineRequest{}, _shape), do: []

  defp run_ops(state, shape, carry, ops, pctx, ctx) do
    Enum.reduce_while(ops, {:ok, state, shape, carry}, fn plan_op, {:ok, state, shape, carry} ->
      case run_op(state, shape, carry, plan_op, pctx, ctx) do
        {:ok, _state, _shape, _carry} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Neutral delegation — Task 8 adds the resize/padding/canvas clauses above
  # this one.
  defp run_op(state, shape, carry, plan_op, _pctx, ctx) do
    state = overlay(state, shape)
    {ops, continuation} = NeutralResolver.resolve(shape, nil, plan_op)

    with {:ok, state} <- run_chain(ctx, state, ops),
         {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
      {:ok, state, shape, carry}
    end
  end

  # overlay/2, follow/5, run_chain/3, flush_boundary/3, build_ctx/1: copied
  # verbatim from lib/image_pipe/dialect/native/pipeline.ex (lines 166-273 —
  # build_ctx, default_measure_dims, overlay, follow, run_chain,
  # flush_boundary, boundary_source_dimensions). The ONLY change: none —
  # these are the shared mechanics; flush_boundary is now called once per
  # pipeline by run_pipeline/3 instead of once per request.
end
```

Copy the named native functions verbatim (they are the proven mechanics; the scoping difference lives entirely in `run/4`/`run_pipeline/3` calling them per pipeline).

- [ ] **Step 4:** `mix test test/image_pipe/dialect/imgproxy/pipeline_scoping_test.exs` — the empty-request test PASSES; the two-pipeline tests still FAIL (no ops assembled yet — `operations/2` returns `[]`). Mark those two `@tag :pending_task_9` with `ExUnit.configure(exclude: [:pending_task_9])`? **No** — instead write them against a minimal hand-rolled `operations/2` stub? **No.** Correct TDD resolution: the two scoping tests drive a *minimal* `operations/2` that handles ONLY `width`/`height` (a bare `Operation.resize(:fit, …)` from `preq.width`/`preq.height`, nil-safe) — just enough to observe scoping. Task 9 replaces it with the full 8-stage assembly and keeps these tests green.
- [ ] **Step 5:** Implement the minimal `operations/2` (resize-only); all three tests PASS.
- [ ] **Step 6: Gate + commit:** `git commit -m "Dialect.Imgproxy.Pipeline: per-pipeline seed/carry/flush skeleton (spec §Pipeline 1)"`

---

### Task 8: `Pipeline` part 2 — carry math + marker-free padding/canvas

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy/pipeline.ex`
- Test: `test/image_pipe/dialect/imgproxy/pipeline_carry_test.exs`

**Interfaces:**
- Consumes: Task 7's skeleton; `Transform.{Lowering, ResizePlanning, Operation.Resize}` (exported, Task 5 comment); `Plan.Operation.{Resize, Padding, Canvas}`.
- Produces: `run_op/6` clauses for `%Plan.Operation.Resize{}`, `%Plan.Operation.Padding{}`, `%Plan.Operation.Canvas{}`; `pipeline_ctx/1` deriving `mode` + `dpr_fallback` from `PipelineRequest`.

- [ ] **Step 1: Write the failing carry tests.** Key cases (the spec's pinned list):

```elixir
# 1. resize computes both carry slots (assert via recorded padding executables:
#    a no-enlarge resize on a smaller source caps the padding scale — the
#    !Enlarge() DprScale block).
# 2. padding AFTER a resize consumes carry.effective_padding_scale (mode
#    :resize) — Lowering.padding_executables receives the capped scale, not
#    the raw dpr.
# 3. padding in a pipeline whose PipelineRequest has extend set consumes the
#    canvas_preserving slot (mode :canvas_preserving — uncompensated).
# 4. canvas ALWAYS consumes canvas_preserving_padding_scale || 1.0 (the
#    resolver.ex:57-58 rule — canvas fallback is 1.0, NOT dpr).
# 5. padding with NO resize in its own pipeline falls back to dpr_fallback
#    (== preq.dpr), NEVER a preceding pipeline's computed scale — build a
#    two-pipeline request where p1 resizes (capping to 0.5) and p2 has only
#    padding + dpr 2.0: p2's padding must scale by 2.0.
# 6. a trim between resize and padding does not lose the carry (the
#    resolver.ex delegation comment's own regression case).
```

Write these with the `:chain` injection seam recording executable ops; assert on the `%Transform.Operation.Padding{top: …}` / `%Transform.Operation.ExtendCanvas{}` field values (scaled sides). For expected values, compute by hand from `Lowering.scaled_padding_side/2`'s arithmetic.

- [ ] **Step 2:** Run — FAIL (no resize/padding/canvas clauses).
- [ ] **Step 3: Implement.**

```elixir
# pipeline_ctx: the mode is parse-time-decidable request data (spec D5) —
# ports plan_builder.ex:677-686. Port the predicate CLOSURE verbatim:
# extend_operation_requested?, extend_aspect_ratio_emits?, AND their
# helpers extend_aspect_ratio_requested? and resize_target_ratio — the
# last reads width/height, not extend* fields (plan_builder.ex:479-487),
# so a port that only copies the extend*-field readers silently changes
# the mode for aspect-ratio-extend requests.
defp pipeline_ctx(%PipelineRequest{} = preq) do
  mode =
    if extend_operation_requested?(preq) or extend_aspect_ratio_emits?(preq),
      do: :canvas_preserving,
      else: :resize

  %{mode: mode, dpr_fallback: preq.dpr || 1.0}
end

defp run_op(state, shape, _carry, %PlanResize{} = op, _pctx, ctx) do
  # Carry is computed here, from the PRE-resolve shape, before any
  # continuation is followed — reproducing resolver.ex:37-49 exactly; it is
  # never recomputed in follow/5 [spec §Pipeline 2 "update point"].
  branch = NeutralResolver.resolve_mode(op, shape)

  carry = %{
    effective_padding_scale: padding_scale(op, shape, branch, :resize),
    canvas_preserving_padding_scale: padding_scale(op, shape, branch, :canvas_preserving)
  }

  state = overlay(state, shape)
  {ops, continuation} = NeutralResolver.resolve(shape, nil, op)

  with {:ok, state} <- run_chain(ctx, state, ops),
       {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
    {:ok, state, shape, carry}
  end
end

defp run_op(state, shape, carry, %PlanPadding{} = op, pctx, ctx) do
  state = overlay(state, shape)
  ops = Lowering.padding_executables(op, padding_scale_for(pctx, carry))
  {ops, continuation} = NeutralResolver.display_frame_advance(ops, shape)

  with {:ok, state} <- run_chain(ctx, state, ops),
       {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
    {:ok, state, shape, carry}
  end
end

defp run_op(state, shape, carry, %PlanCanvas{} = op, _pctx, ctx) do
  state = overlay(state, shape)
  ops = Lowering.canvas_executables(op, carry.canvas_preserving_padding_scale || 1.0)
  {ops, continuation} = NeutralResolver.plain_advance(ops, shape)

  with {:ok, state} <- run_chain(ctx, state, ops),
       {:ok, state, shape} <- follow(state, shape, continuation, ctx, 0) do
    {:ok, state, shape, carry}
  end
end

# The two fallbacks are DIFFERENT (old resolver.ex clauses 151-168): padding
# falls back to the request dpr; canvas falls back to 1.0.
defp padding_scale_for(%{mode: :resize, dpr_fallback: fb}, %{effective_padding_scale: s}),
  do: s || fb

defp padding_scale_for(
       %{mode: :canvas_preserving, dpr_fallback: fb},
       %{canvas_preserving_padding_scale: s}
     ),
     do: s || fb

# padding_scale/4, max_padding_scale_without_enlarge/2,
# compensate_no_enlarge_padding_scale/3, tagged_dpr_float/1,
# display_source_dims/1: copied VERBATIM from
# lib/image_pipe/parser/imgproxy/resolver.ex:87-174. One adjustment:
# tagged_dpr_float receives {:ratio, n, d} in the old code (the Plan op's
# tagged dpr); the copied functions keep that signature — the Plan.Operation
# structs are unchanged.
```

`%Plan.Operation.Padding{}` construction note: the dialect (Task 9) emits padding via the plain constructor with `pixel_ratio` as a concrete `{:ratio, n, d}` (from `preq.dpr`), NEVER `{:effective, …}` — but `Lowering.padding_executables/2` takes the scale as an argument and ignores `pixel_ratio` entirely, so the field value is inert here. The marker-never-constructed assertion lives in Task 9's assembly tests.

- [ ] **Step 4:** Run — all six carry tests PASS; Task 7's scoping tests still PASS.
- [ ] **Step 5: Gate + commit:** `git commit -m "Dialect.Imgproxy.Pipeline: pipeline-local carry, marker-free padding/canvas (spec D5)"`

---

### Task 9: `Pipeline` part 3 — 8-stage assembly, color preamble, decode preflight

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy/pipeline.ex` (real `operations/2`, `condition_color/2`, `decode_request/2`)
- Modify: `lib/image_pipe/transform/decode_planner.ex` (the `user_quarter_turn?` field on `DecodePlanner.Request` + the XOR in `open_options_for/5` — see Interfaces; sanctioned core widening, named here per the Global Constraints rule)
- Test: `test/image_pipe/dialect/imgproxy/pipeline_assembly_test.exs`, `test/image_pipe/dialect/imgproxy/decode_preflight_test.exs`, `test/image_pipe/transform/decode_planner_test.exs` (the new-field unit case)

**Interfaces:**
- Consumes: `Transform.InputColorManagement.condition/2` (Task 5); `plan_builder.ex`'s geometry helpers (ported); `DecodePlanner.Request` struct.
- Produces:
  - `operations(PipelineRequest.t(), SourceShape.t()) :: [struct()]` — the 8-stage `Plan.Operation` list: `trim → orientation → crop → resize → effects → canvas → padding → background`, a verbatim port of `plan_builder.ex`'s `plan_geometry/1` (`plan_builder.ex:270-289`) and every private helper it reaches (`trim_operations/1` through `background_operations/1`). **One deliberate change:** padding emission uses a concrete `pixel_ratio: dpr_ratio(preq)` instead of `effective_padding_pixel_ratio/1` — the `{:effective, …}` marker is never constructed (D5); mode/fallback live in `pipeline_ctx/1` (Task 8).
  - `Pipeline.run/4` opens with the color preamble **before the pipeline reduce**: `InputColorManagement.condition(state, supports_hdr?: opts[:supports_hdr?] || false)`, error → `{:error, {:decode, reason}}` (mirrors `Executor.run_color_management/2`, `executor.ex:100-113`).
  - `Pipeline.decode_request(request, SourceGeometry.t()) :: DecodePlanner.Request.t()` — FIRST pipeline only: `resize_target` from the first pipeline's width/height resolved against display dims (or crop extent when a crop precedes — mirror `native/pipeline.ex:82-125`'s resolution rules with imgproxy's zero-sentinel-already-resolved inputs), `crop_extent` from `preq.crop`, `trim?: preq.trim != nil`, `terminal_reduction: nil`, `required_extent: nil`, **`user_quarter_turn?`** (below).
  - **Core widening (small, this task): `DecodePlanner.Request` gains a `user_quarter_turn? :: boolean()` field (default `false`), and `open_options_for/5`'s axis-swap decision becomes `(exif_quarter_turn? and auto_rotate?) XOR user_quarter_turn?`.** Why: the framework's chain path computes `net_quarter_turn?` as `rem(exif_angle + user_rotate_angle_before_resize(chain), 180) == 90` (`decode_planner.ex:148-164`) — a user `rot:90` before the resize swaps the shrink axes, and real imgproxy folds `po.Rotate()` into `ExtractGeometry`'s swap the same way (`processing/prepare.go`). The native-shaped `open_options_for/5` knows only the EXIF turn, so a dialect using it unmodified computes the **wrong shrink axis** whenever EXIF turn XOR user turn differs from EXIF turn alone. Concrete would-fail fixtures: `exif_5_cover_rot90` / `exif_7_cover_rot90` (`constellations.ex:849-850` — EXIF quarter turn + `rot:90` = net 180, framework does NOT swap, unpatched dialect would). The XOR is exact because each term is 0 or 90 mod 180. The dialect computes `user_quarter_turn?` from the first pipeline's `preq.orientation` rotate angle: `rem(angle, 180) == 90`. The framework's own `open_options/5` chain path is untouched; this widening is the same species as the probe's other `DecodePlanner.Request` transitional gaps (probe report §7 item 3).

- [ ] **Step 1: Write failing assembly tests.** Cases: (a) stage ORDER — a `PipelineRequest` with all eight concerns set yields ops in exactly the 8-stage order (assert on the module sequence of `operations/2`'s return); (b) **the marker is never constructed** — for a padding+dpr request, assert `match?({:ratio, _, _}, padding_op.pixel_ratio)` and `refute match?({:effective, _, _}, …)`; (c) zero-sentinel resize (`width: {:pixels, 0}`) yields an `:auto` dimension (port the expectations from `plan_builder_test.exs`'s corresponding cases — read that file for the exact expected structs); (d) empty `PipelineRequest` yields `[]`.
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3: Port `plan_geometry/1` + helpers** from `plan_builder.ex` verbatim (they consume `PipelineRequest` and emit `Plan.Operation` structs via `ImagePipe.Plan.Operation` constructors — all exported). The port's ONLY functional change is the padding `pixel_ratio` above. Where `plan_builder` helpers reference `ParsedRequest`, they don't for geometry (verify — geometry helpers take `%PipelineRequest{}`).
- [ ] **Step 4:** Assembly tests PASS.
- [ ] **Step 5: Write + implement the color-preamble test:** a `run/4` call on a stub state with `color_imported?: false` and an injected `:chain` — assert `InputColorManagement.condition/2` ran before the first chain call (observable: use a real small P3-tagged image from `test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png` and assert the state's `color_imported?` is true after `run/4` with zero pipelines... the empty-pipeline case makes this a pure preamble test). Check `SourceInventory`'s `consumers` note for `icc_p3.png` before using it (AGENTS.md) — read-only use adds no inventory entry.
- [ ] **Step 6: Write + implement decode-preflight tests** (`decode_preflight_test.exs`): first-pipeline-only scoping (two pipelines, second has the resize → `resize_target: nil`); `trim?` true when first pipeline trims; crop extent resolution; **the user-rotate axis swap**: (a) EXIF-1 + `rot:90` + resize → `user_quarter_turn?: true` and `DecodePlanner.open_options_for` swaps the shrink axes; (b) EXIF-6 (quarter turn) + `rot:90` + auto-rotate on → net 180, NO swap (the `exif_5_cover_rot90` regression shape); (c) `rot:180` → no swap. Plus a `DecodePlanner`-unit test for the new field (both XOR arms). Expected values computed by hand.
- [ ] **Step 7:** All pipeline tests PASS (`mix test test/image_pipe/dialect/imgproxy/`).
- [ ] **Step 8: Gate + commit:** `git commit -m "Dialect.Imgproxy.Pipeline: 8-stage assembly, color preamble (G4), decode preflight"`

---

### Task 10: Copy grammar — `Signature`, `SourceEncryption`, `PercentEncoding`, `Presets` (+ dual-run tests)

**Files:**
- Create (copies from `lib/image_pipe/parser/imgproxy/`): `lib/image_pipe/dialect/imgproxy/signature.ex`, `source_encryption.ex`, `percent_encoding.ex`, `presets.ex`
- Modify (convert to dual-run in place): `test/parser/imgproxy/signature_test.exs`, `test/parser/imgproxy/source_encryption_test.exs`
- Create: `test/image_pipe/dialect/imgproxy/presets_dual_test.exs` if `presets` has its own test file (check: `ls test/parser/imgproxy/`); otherwise its coverage arrives with Task 12's options tests
- Modify: `.credo.exs` + `mise.toml` ExDNA ignores (add the four files)

**Interfaces:**
- Produces: `ImagePipe.Dialect.Imgproxy.{Signature, SourceEncryption, PercentEncoding, Presets}` — API-identical copies. `Signature.verify/3`, `Signature.normalize_config!/1`, `Signature.disabled/0`; `Presets.validate_config/1`, `Presets.empty/0`.
- **The dual-run pattern** (used verbatim in Tasks 12–13 too): convert each existing test file in place —

```elixir
# BEFORE (test/parser/imgproxy/signature_test.exs):
#   alias ImagePipe.Parser.Imgproxy.Signature
#   ... 20 tests calling Signature.* ...
#
# AFTER — the same file becomes:
for {impl, suffix} <- [
      {ImagePipe.Parser.Imgproxy.Signature, Framework},
      {ImagePipe.Dialect.Imgproxy.Signature, Dialect}
    ] do
  defmodule Module.concat(ImgproxySignatureTest, suffix) do
    use ExUnit.Case, async: true

    @signature impl

    # every former `Signature.foo(...)` call becomes `@signature.foo(...)`
    # — a mechanical alias→attribute substitution; test bodies and
    # assertions are otherwise UNCHANGED (a changed assertion would defeat
    # the copy-fidelity purpose).
  end
end
```

Phase 2 drops the Framework tuple from the list — that is the whole retirement diff for these files.

- [ ] **Step 1: Copy + rename** the four modules: for each, `cp lib/image_pipe/parser/imgproxy/X.ex lib/image_pipe/dialect/imgproxy/X.ex`, rename the module `ImagePipe.Parser.Imgproxy.X` → `ImagePipe.Dialect.Imgproxy.X`, and rewire any alias between the four to the dialect copy (verify with `grep -n "alias" lib/image_pipe/dialect/imgproxy/{signature,source_encryption,percent_encoding,presets}.ex` — expected: `signature.ex` and `presets.ex` are self-contained; `source_encryption.ex` has no ImagePipe aliases).
- [ ] **Step 2: Convert `signature_test.exs`** to the dual-run pattern. Run: `mix test test/parser/imgproxy/signature_test.exs` — expected: **40 tests** (20 × 2), all PASS.
- [ ] **Step 3: Convert `source_encryption_test.exs`** the same way — 16 tests (8 × 2), PASS.
- [ ] **Step 4: ExDNA ignores** for the four new files in both `.credo.exs` and `mise.toml`.
- [ ] **Step 5: Gate + commit:** `git commit -m "Dialect.Imgproxy: copy signature/encryption/encoding/presets; dual-run their unit tests"`

---

### Task 11: `Dialect.Imgproxy.Request` — the canonical struct

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/request.ex` (from `lib/image_pipe/parser/imgproxy/parsed_request.ex`)
- Test: `test/image_pipe/dialect/imgproxy/request_test.exs`
- Modify: `.credo.exs` + `mise.toml` ExDNA ignores

**Interfaces:**
- Produces: `ImagePipe.Dialect.Imgproxy.Request` — field-identical to `ParsedRequest` (`signature`, `source_kind`, `source_path`, `pipelines`, `info?`, `auto_rotate`, `output`, `policy`, `cache`, `response` with the same defaults, `parsed_request.ex:6-33`), plus the same helper constructors (`output_request/1`, `policy_request/1`, `cache_request/1`, `response_request/1`). The `pipelines` type points at the **dialect's** `PipelineRequest`. This is the canonical pre-fetch value (spec: pure data, no PIDs/conn state); Tasks 12, 15, 17 consume it.

- [ ] **Step 1: Copy + rename** (`ParsedRequest` → `Request`; `Parser.Imgproxy.PipelineRequest` alias → `Dialect.Imgproxy.PipelineRequest`).
- [ ] **Step 2: Test:** field/default equivalence vs `ParsedRequest` (same shape-compare pattern as Task 6's test) + a purity assertion that actually discriminates (a `term_to_binary` round-trip is vacuous — pids/refs/funs survive it equal on the same node):

```elixir
test "the canonical request is pure data (no pid/ref/function leaves)" do
  request = %ImagePipe.Dialect.Imgproxy.Request{
    signature: "unsafe", source_kind: :plain, source_path: "images/x.jpg",
    pipelines: [%ImagePipe.Dialect.Imgproxy.PipelineRequest{}]
  }

  assert pure_data?(request)
end

defp pure_data?(%_{} = struct), do: struct |> Map.from_struct() |> pure_data?()
defp pure_data?(%{} = map), do: map |> Map.to_list() |> pure_data?()
defp pure_data?(list) when is_list(list), do: Enum.all?(list, &pure_data?/1)
defp pure_data?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> pure_data?()

defp pure_data?(term),
  do: not (is_pid(term) or is_reference(term) or is_function(term) or is_port(term))
```

- [ ] **Step 3:** PASS; ExDNA ignore; gate; `git commit -m "Dialect.Imgproxy.Request: canonical pre-fetch request struct"`

---

### Task 12: Copy grammar — `OptionGrammar` + `Options` (+ dual-run tests)

The largest copy (1,569 + 574 lines) and the one real edit: `parse_boolean` localization.

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/option_grammar.ex`, `lib/image_pipe/dialect/imgproxy/options.ex`
- Modify (dual-run in place): `test/parser/imgproxy/option_grammar_test.exs` (66 tests), `test/parser/imgproxy/options_test.exs` (53 tests)
- Modify: `.credo.exs` + `mise.toml` ExDNA ignores

**Interfaces:**
- Consumes: Tasks 6, 10, 11 modules.
- Produces: `ImagePipe.Dialect.Imgproxy.Options.parse([String.t()], Presets.t(), keyword()) :: {:ok, request_options} | {:error, term()}` where `request_options` is the map with `:pipelines, :auto_rotate, :output, :policy, :cache, :response` keys (`options.ex:36-48` shape, unchanged). Task 17's chain calls this.
- **The one real edit** (spec Module map): `option_grammar.ex:709` calls `ImagePipe.Parser.parse_boolean/1`. In the copy, add a private local:

```elixir
# Localized from ImagePipe.Parser.parse_boolean/1 — the dialect must not
# depend on the Parser boundary (acid test). Copy that function's exact
# clauses (read lib/image_pipe/parser.ex for the definitive list of accepted
# spellings — "1"/"true"/"t" etc.) so framework and dialect accept identical
# boolean spellings; the dual-run grammar tests pin the equivalence.
defp parse_boolean(value), do: ...
```

- Every other framework reference in the two files (`Plan.Color`, `Plan.Output.*Options`, `Plan.Response`, `ImagePipe.Config.encoder_options_from_config/1`, `QualitySearch.build/3`) **stays** — shared value types / the shared `ImagePipe.Config` boundary.

- [ ] **Step 1: Copy + rename** the two files; rewire internal aliases to the dialect copies (`PipelineRequest`, `Effects`, `CropRequest`, `Orientation`, `Presets`, `Request` for the former `ParsedRequest` — `options.ex` calls `ParsedRequest.output_request()` etc.: those become `Request.output_request()`); localize `parse_boolean`.
- [ ] **Step 2: Dual-run convert `option_grammar_test.exs`** (Task 10's exact pattern; the substituted alias is `OptionGrammar` → `@grammar`). Run: 132 tests (66 × 2), PASS.
- [ ] **Step 3: Dual-run convert `options_test.exs`** (aliases `Options`, and its `ParsedRequest` references become the impl-paired `Request` — parameterize BOTH as attributes: `for {options_impl, request_impl, suffix} <- [{Parser…Options, Parser…ParsedRequest, Framework}, {Dialect…Options, Dialect…Request, Dialect}]`). Run: 106 tests (53 × 2), PASS.
- [ ] **Step 4:** ExDNA ignores; gate; commit: `git commit -m "Dialect.Imgproxy: copy OptionGrammar+Options (parse_boolean localized); dual-run 119 grammar tests"`

---

### Task 13: Copy grammar — `Path`, `Source`, `SourceScheme` (+ dual-run tests)

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/path.ex`, `source.ex`, `source_scheme.ex`
- Modify (dual-run in place): `test/parser/imgproxy/path_test.exs` (45), `test/parser/imgproxy/source_test.exs` (19)
- Modify: `.credo.exs` + `mise.toml` ExDNA ignores

**Interfaces:**
- Produces: `ImagePipe.Dialect.Imgproxy.Path.split_endpoint/1`, `extract/1`, `split_source/2`, `parse_source/3`, `parse_source_no_extension/3` (signatures per `path.ex`); `…Source.translate(String.t(), keyword()) :: {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}`; `…SourceScheme` — the **host-facing behaviour** (callback returns `ImagePipe.Plan.Source.t()`); it will be the dialect boundary's one export (Task 17).
- `Path` copies its own `parser_request_path/1` mount handling — the dialect inherits imgproxy's existing mount semantics, NOT native's `script_name` approach (spec §Mount / path semantics).

- [ ] **Step 1: Copy + rename** (internal aliases: `Path` uses `Format`, `PercentEncoding`, `SourceEncryption` — all already copied; `Source` builds `Plan.Source.*` — stays).
- [ ] **Step 2: Dual-run convert** `path_test.exs` (90 tests PASS) and `source_test.exs` (38 tests PASS).
- [ ] **Step 3: Add the export.** In the Task 6 Boundary stub (`lib/image_pipe/dialect/imgproxy.ex`), change `exports: []` to `exports: [SourceScheme]` — the host-facing behaviour now exists.
- [ ] **Step 4:** ExDNA ignores; gate; commit: `git commit -m "Dialect.Imgproxy: copy Path/Source/SourceScheme; dual-run their tests"`

---

### Task 14: `Config` — the three-way split

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/config.ex`
- Test: `test/image_pipe/dialect/imgproxy/config_test.exs`

**Interfaces:**
- Consumes: `SharedConfig` (Task 4), `ImagePipe.Config.resolve!/2`, dialect `Signature.normalize_config!/1` + `Presets.validate_config/1` + `SourceEncryption.validate_key/1` (copies).
- Produces: `ImagePipe.Dialect.Imgproxy.Config.validate!(keyword()) :: keyword()` — the Plug `init/1` validator. Three-way split (spec Core changes §1):

```elixir
def validate!(opts) when is_list(opts) do
  {shared, rest} = Keyword.split(opts, SharedConfig.keys())
  {neutral, rest} = Keyword.split(rest, ImagePipe.Config.keys())
  {dialect, unknown} = Keyword.split(rest, @dialect_keys)

  unless unknown == [] do
    raise ArgumentError,
          "unknown ImagePipe.Dialect.Imgproxy option(s): #{inspect(Keyword.keys(unknown))}"
  end

  SharedConfig.validate_runtime!(shared)
  |> Keyword.merge(ImagePipe.Config.resolve!(neutral, imgproxy_overlay()))
  |> Keyword.merge(validate_dialect!(dialect))
end

# @dialect_keys and validate_dialect! port imgproxy.ex:33-59 + 118-128:
# :signature (-> Signature.normalize_config!), :source_url_encryption_key
# (-> normalized to :source_url_encryption), :base64_url_includes_filename,
# :source_schemes, :presets — PLUS :clock (arity-0 function, default
# fn -> System.os_time(:second) end), which the framework carries as a
# request option (request/options.ex:17, read at plan_builder.ex:196) and
# the wire suite injects for its expiry tests; Task 17's check_expires
# reads it. imgproxy_overlay/0 is [] (imgproxy.ex:64 — "imgproxy parity ==
# neutral defaults").
```

Note the shape change vs the framework: the framework nests everything under a `:imgproxy` key inside `ImagePipe.Plug`'s opts; the dialect takes a FLAT keyword (native's precedent). The dual-run test helpers (Task 19–20) own the translation.

- [ ] **Step 1: Failing tests:** defaults applied; unknown key raises; `signature: [keys: [...], salts: [...]]` normalizes; `presets:` validates; neutral key (`quality: 80`) resolves through `ImagePipe.Config`.
- [ ] **Step 2–3:** Implement; PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy.Config: SharedConfig + neutral Config + dialect keys (three-way split)"`

---

### Task 15: `Identity` + `Negotiation`

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/identity.ex`, `lib/image_pipe/dialect/imgproxy/negotiation.ex`
- Test: `test/image_pipe/dialect/imgproxy/identity_test.exs`

**Interfaces:**
- Consumes: `Request` (Task 11); core `Representation`/`IdentityMaterial`, `Output.Policy` (`from_output_plan/3`, `ensure_capable/2`, `identity_selection/1`, `identity_material/1`), `Plan.Output`.
- Produces (mirrors `native/identity.ex` + `native/negotiation.ex` — read both first):
  - `%Negotiation{selected: {:image, format | :source_negotiated} | {:terminal, :info}, vary?: boolean(), policy_material: keyword(), policy: Policy.t() | nil}` (same fields as native's struct, `native/negotiation.ex`).
  - `Identity.plan_output(Request.t()) :: Plan.Output.t()` — builds the FULL output intent from `request.output` (unlike native's mode+quality-only version): `mode` from `format` (`{:explicit, f}` | `:automatic`), `quality`, `format_qualities`, `max_bytes`, `quality_search`, `strip_metadata`, `keep_copyright`, `strip_color_profile`, `color_profile`, `preserve_hdr`, `encoder_options` — mapping each `request.output` field onto the corresponding `%Plan.Output{}` field. Read `lib/image_pipe/plan/output.ex` for the exact field names/defaults and `plan_builder.ex`'s output-mapping section (grep `Plan.Output` in it) for the framework's existing mapping — port it verbatim.
  - `Identity.material(Request.t(), Negotiation.t(), Plug.Conn.t(), keyword()) :: IdentityMaterial.t()`:
    - `representation`: `[pipelines: canonical_pipelines(request.pipelines), auto_rotate: request.auto_rotate] ++ selection_material(negotiation.selected) ++ [output: canonical_output(request.output), output_policy: negotiation.policy_material]` where `canonical_pipelines` maps each `PipelineRequest` through `Map.from_struct` (recursing into `effects`/`orientation` structs) and `canonical_output` is `Map.from_struct`-style on the output map.
    - `storage_only`: `[cachebuster: request.cache.cachebuster] ++ storage-input values` via `Representation.storage_inputs(conn, config[:storage_inputs] || [])`.
    - `dialect_behavior`: `{ImagePipe.Dialect.Imgproxy, 1}`.
    - `vary_header_names`: storage vary names ++ `["Accept"]` when `negotiation.vary?`.
    - **Excluded** (spec §Identity): `signature`, `expires` (`request.policy`), `source_path`, and ALL of `request.response` (`filename`/`disposition`/`debug?`).
  - `negotiate(conn, request, config)` — lives on the chain module in Task 17 (native's precedent: a `@doc false` public fn); this task builds the structs + material it needs.

- [ ] **Step 1: Failing tests** (construct `%Request{}` values directly — this is the dialect's own boundary, its tests may build its own structs):
  - two requests differing only in `response.filename` → equal `IdentityMaterial`;
  - two requests differing only in `response.debug?` → equal material;
  - differing `cache.cachebuster` → equal `representation`, differing `storage_only`;
  - differing `signature`/`policy.expires` → equal material;
  - differing `auto_rotate` → differing `representation`;
  - `vary_header_names` gains `"Accept"` iff `vary?`.
- [ ] **Step 2–3:** Implement; PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy: Identity material + Negotiation (response fields excluded from identity)"`

---

### Task 16: `Errors`

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/errors.ex`
- Test: `test/image_pipe/dialect/imgproxy/errors_test.exs`

**Interfaces:**
- Consumes: `Response.ErrorStatus.classify/1`.
- Produces: `Errors.send(Plug.Conn.t(), reason :: term(), keyword()) :: Plug.Conn.t()` with imgproxy's protocol mapping (spec §Errors). **Body strings must match the framework's exactly** — the dual-run wire suite (Task 19) asserts bodies. The framework's strings (`imgproxy.ex:213-239`): signature failures → 403, and note the framework inspects the **bare atom**, not the caught tuple — `send_signature_error/2` receives `:invalid_signature`, `:invalid_signature_encoding`, or `:unsupported_signature`, so the body is e.g. `"invalid image request: :invalid_signature_encoding"` even when the caught reason was `{:invalid_signature_encoding, sig}`; every other parse error → 400 `"invalid image request: #{inspect(reason)}"`; content type `text/plain`. **Expired → 400, NOT 404**: the framework's expiry produces `{:error, {:expired_request, expires}}` (`plan_builder.ex:186-188`) which falls to the generic clause → 400 body `"invalid image request: {:expired_request, N}"`, pinned by the wire suite (`imgproxy_wire_conformance_test.exs:4509` "an expired /info URL returns 400") and documented as a known divergence from upstream imgproxy's 404 (`docs/imgproxy_support_matrix.md:1181`). For post-parse stage errors, mirror the statuses + bodies the wire suite pins (read them: `grep -n "resp_body ==" test/image_pipe/imgproxy_wire_conformance_test.exs | head -30`).

- [ ] **Step 1: Failing tests** — one per mapping row (signature 403 with exact bare-atom body, parse 400 with exact body, `{:expired_request, n}` → **400** with the framework's exact body, `{:source, {:bad_status, 503}}` → 502, `{:decode, :x}` → 415, `{:transform, :x}` → 422).
- [ ] **Step 2–3:** Implement (clause table + `ErrorStatus` fallback, mirroring `native/errors.ex`'s structure); PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy.Errors: protocol status mapping (bodies framework-identical)"`

---

### Task 17: The chain — `imgproxy.ex` image path

**Files:**
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (the Task 6 Boundary stub gains `@behaviour Plug` and the chain; the `use Boundary` block below is already in place from Tasks 6/13 — verify it matches, don't re-declare)
- Test: `test/image_pipe/dialect/imgproxy_wire_smoke_test.exs`

**Interfaces:**
- Consumes: everything above. The worked example is `lib/image_pipe/dialect/native.ex` — read it in full first; this module mirrors its `route/serve/generate/build_fun` shape with the imgproxy differences below.
- Produces: `ImagePipe.Dialect.Imgproxy` — `@behaviour Plug`; `init/1 → Config.validate!/1`; `call/2` behind a `[:request]` telemetry span.

```elixir
use Boundary,
  top_level?: true,
  deps: [
    ImagePipe.Cache,
    ImagePipe.Config,
    ImagePipe.Decode,
    ImagePipe.Delivery,
    ImagePipe.Dialect.SharedConfig,
    ImagePipe.Error,
    ImagePipe.Format,
    ImagePipe.Output,
    ImagePipe.Plan,
    ImagePipe.Representation,
    ImagePipe.Response,
    ImagePipe.Source,
    ImagePipe.Telemetry,
    ImagePipe.Transform
  ],
  exports: [SourceScheme]
```

The chain (spec §The visible chain — `/info/` branch is Task 18; this task returns 404 for it temporarily via a `{:error, :info_not_implemented}` clause the next task deletes):

```elixir
defp route(%Plug.Conn{} = conn, config) do
  case Path.split_endpoint(conn) do
    {:info, _info_conn} -> Errors.send(conn, :info_not_implemented, config)  # Task 18 replaces
    :image -> route_image(conn, config)
  end
end

defp route_image(conn, config) do
  now = System.os_time(:second)

  with {:ok, request} <- parse(conn, config),          # extract → verify → split_source → Options.parse → Path.parse_source → %Request{}, inside a [:parse] span
       :ok <- check_expires(request, now),             # request.policy.expires; 0 = disabled; failure -> {:error, {:expired_request, expires}} -> 400 (Task 16); mirror plan_builder.ex:181-188's comparison exactly
       {:ok, plan_source} <- ImgproxySource.translate(request.source_path, source_parsing_config(config)),
       {:ok, resolved} <- ImageSource.resolve(plan_source, config, config),
       {:ok, negotiation} <- negotiate(conn, request, config) do
    representation =
      Representation.build(resolved.identity, Identity.material(request, negotiation, conn, config))

    if Conditional.not_modified?(conn, representation.etag) do
      Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
    else
      serve(conn, request, resolved, negotiation, representation, config)
    end
  else
    {:error, reason} -> Errors.send(conn, reason, config)
  end
end
```

`parse/2` composes the copied grammar exactly as `imgproxy.ex:156-177` (`parse_image_request/2`) does — `Path.extract` → `Signature.verify` → `Path.split_source` → `Options.parse(segments, presets, request_defaults)` → `Path.parse_source` → build `%Request{}` (the `parsed_request/4` output-format merge at `imgproxy.ex:293-313`: `output_format = source_format || request_options.output.format`). `serve/6`, `deliver_hit/5`, `generate/6` (image), `build_fun/4`, `cache_headers/1`, `vary_headers/1`: mirror native's (`native.ex:214-295, 362-431`) with these imgproxy differences:
  1. `auto_rotate?` is **request data**: `Keyword.put(config, :auto_rotate?, request.auto_rotate)` (closes G1) — not native's fixed `@auto_rotate? true`.
  2. `supports_hdr?` threads from the negotiated output into `Pipeline.run`'s opts (Task 9's preamble): compute from `Format.supports_hdr?(selected_format)` + the output's `preserve_hdr`/`hdr` policy — read how the framework threads it (`grep -rn supports_hdr lib/image_pipe/`) and mirror.
  3. `response_meta` is NOT native's empty `%PlanResponse{}`: build it from `request.response` (`filename`, `disposition`, `debug?` — read `lib/image_pipe/plan/response.ex` for the constructor) so cache hits and misses carry the CURRENT request's disposition (spec §Identity "why sharing an entry is safe").
  4. Result limits: use the host-config values via `ImagePipe.Config` keys if present (grep `max_result` in `lib/image_pipe/config.ex`; if the framework exposes them as request options instead, mirror the framework's source — `Output.Clamp` call sites in `request/processor.ex`).

- [ ] **Step 1: Write failing wire smoke tests** (pattern: `native_wire_test.exs`'s `opts/1` + `get/3` helpers, `@default_sources` from `RootHTTPAdapter` + `OriginImage`). **URL shape:** use the wire suite's relative-source form — `/unsafe/…/plain/images/beach.jpg` against the `http://origin.test` root — NOT the differential harness's `local:///` form (which needs its file-serving source wiring; a fresh agent mixing the two gets source-resolution failures):
  - `GET /unsafe/rs:fit:100:100/plain/images/beach.jpg` → 200, decoded dims 100×N;
  - option-order equivalence: `/unsafe/w:100/h:80/...` vs `/unsafe/h:80/w:100/...` → byte-identical bodies;
  - signature required: config with `signature: [keys: [...], salts: [...]]` + bad sig → 403;
  - `exp:` in the past → **400**, body `"invalid image request: {:expired_request, N}"` (the framework's pinned divergence from upstream's 404 — Task 16);
  - ETag present; second request with `If-None-Match` → 304 **with a should-not-fetch source** (pre-fetch conditional);
  - `fn:name.jpg` sets `content-disposition` on BOTH miss and cache-hit responses (stateful `CacheProbe`);
  - conditional × response-meta: two requests differing only in `fn:` share an ETag, and an `If-None-Match` with that ETag → 304 regardless of which `fn:` spelling the conditional request carries (spec §Identity's If-None-Match pin);
  - a `debug?`-only pair: the same request with and without the debug option produces **byte-identical bodies** and equal ETags (spec §Identity — `debug?` is header-only, pinned by test, not prose; grep `option_grammar.ex` for the debug option's URL spelling).

Additional chain contracts for this task:
  - **`[:parse]` stop metadata:** carries `result:` plus `sig_key_index:` when signing keys are configured — mirroring native's (`native.ex:161-164`); `sig_key_index` is already in `Trace.Capture`'s `@safe_keys` and `docs/telemetry.md:537`, so no telemetry-surface list changes.
  - **`:clock`:** the wire suite injects a clock (`Keyword.put(@default_opts, :clock, fn -> … end)`, 2 sites; a framework request option read at `plan_builder.ex:196` via `request/options.ex:17`). The dialect Config (Task 14) accepts `:clock` (`is_function/0` arity-0, default `fn -> System.os_time(:second) end`) and `check_expires` uses it instead of a hardcoded `System.os_time/1` — otherwise the dialect arm of the two expiry wire tests cannot be made deterministic.
- [ ] **Step 2:** FAIL (module undefined).
- [ ] **Step 3: Implement** the chain.
- [ ] **Step 4:** Smoke tests PASS.
- [ ] **Step 5: Gate + commit:** `git commit -m "ImagePipe.Dialect.Imgproxy: the inverted chain (image path)"`

---

### Task 18: `/info/` endpoint

**Files:**
- Create: `lib/image_pipe/dialect/imgproxy/info_renderer.ex` (from `lib/image_pipe/parser/imgproxy/info_renderer.ex` — drop `@behaviour ImagePipe.Renderer` and the `RenderContext` param; new signature below)
- Modify: `lib/image_pipe/dialect/imgproxy.ex` (replace the Task 17 stub with the real branch), `lib/image_pipe/dialect/imgproxy/identity.ex` (`{:terminal, :info}` selection material), `negotiation` info clause
- Test: `test/image_pipe/dialect/imgproxy/info_wire_test.exs`

**Interfaces:**
- Produces: `InfoRenderer.render(SourceInfo.t()) :: {content_type :: String.t(), body :: iodata()}` — the same `@wire` table + JSON doc as today (`info_renderer.ex:30-54`), minus the Renderer behaviour.
- The info branch (mirrors native's blurhash complete-body branch, `native.ex:302-360`): parse with `Path.parse_source_no_extension` + `auto_rotate: false`, `info?: true` (the framework's `parse_info_request`, `imgproxy.ex:179-211`); negotiation `%Negotiation{selected: {:terminal, :info}, vary?: false, policy_material: [], policy: nil}`; identity `selection_material({:terminal, :info}) == [terminal: :info]`; generate = `Decode.with_image(resolved, decode_opts, fn _geometry -> %DecodePlanner.Request{resize_target: nil, crop_extent: nil, trim?: false, terminal_reduction: nil, required_extent: nil} end, fn state, geometry -> build SourceInfo end)` where SourceInfo is `%Plan.SourceInfo{format: geometry.source_format, width: elem(geometry.storage_dimensions, 0), height: elem(geometry.storage_dimensions, 1), orientation: exif header read from state.image (`lib/image_pipe/request/render_runner.ex:59-64` pattern), byte_size: nil}`; render → complete-body cache write (`Cache.open_sink(key, {:complete_body, content_type}, config) |> Cache.write_chunk(body) |> Cache.commit_sink()` — native's `write_complete_body_cache/3` pattern) → `send_resp(200, body)` with etag header. Cache hit: the `{:complete_body, content_type}` entry branch native already has (`native.ex:250-261` pattern) — **response headers (etag, content type) are reconstructed from the current request/representation, never read from the stored entry beyond its content type** (spec §The /info/ cache path). Cache write failures fail open exactly as the image path does. G5 (FileSystem doesn't persist complete-body) is a known, recorded non-blocker.

Routing caveat (compat): the info branch must flow through the **copied** `Path.split_endpoint/1` → `Path.extract/1` on the prefix-stripped conn — the signature is verified over the path WITHOUT the `/info` prefix (`path.ex:8, 213-217` + `imgproxy.ex:182-183`), matching upstream. Do not re-derive the signed path in the chain.

- [ ] **Step 1: Failing wire tests:** `/info/unsafe/plain/images/beach.jpg` → 200 `application/json` with `format`/`mime_type`/`width`/`height`/`orientation` keys matching the framework's response for the same request (assert JSON-decoded equality against a framework `ImagePipe.Plug` call — the strongest info-parity check); repeat with a signed config (403 on bad sig); cache hit round-trip via stateful `CacheProbe` (second request served with same body, no second source fetch via counting source); **a cache-write-failure case** (a `CacheProbe` whose `write_chunk` errors → 200 with the correct JSON body, fail-open — the /info analog of the image path's row 7).
- [ ] **Step 2–3:** Implement; PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy: /info endpoint (dialect-owned rendering, complete-body cache)"`

---

### Task 19: Dual-run wire suite

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`

**Interfaces:**
- Consumes: the complete dialect (Tasks 17–18).
- Produces: every wire test runs against both stacks.

- [ ] **Step 1: Normalize the bypass sites.** Find them: `grep -n "ImagePipe.Plug.call\|ImagePipe.Plug.init" test/image_pipe/imgproxy_wire_conformance_test.exs` — expected: `call_imgproxy/3` (`:4327-4334`) plus ~6 inline sites (`:995-1020`, `:2109-2312` region). Convert every inline site to `call_imgproxy/3` (or a sibling helper for the ones needing custom conn setup). Run the suite (framework-only still): PASS, 149 tests.
- [ ] **Step 2: Parameterize.** The file is one big module; convert to the dual-module pattern at the TOP level:

```elixir
for {stack, suffix} <- [{:framework, Framework}, {:dialect, Dialect}] do
  defmodule Module.concat(ImgproxyWireConformanceTest, suffix) do
    use ExUnit.Case, async: true
    @stack stack
    # call_imgproxy/3 dispatches on @stack:
    defp call_imgproxy(path, opts, accept \\ nil) do
      conn = :get |> conn(path) |> put_accept(accept)
      case @stack do
        :framework -> ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
        :dialect -> ImagePipe.Dialect.Imgproxy.call(conn, ImagePipe.Dialect.Imgproxy.init(translate_opts(opts)))
      end
    end
    # translate_opts/1: framework opts nest dialect keys under :imgproxy and
    # carry parser:; the dialect takes a flat keyword (Task 14). Flatten:
    # drop :parser, hoist the :imgproxy sublist, pass sources/cache/:clock
    # through (:clock is a dialect Config key per Task 14 — the expiry tests
    # need it on both arms).
    ...
  end
end
```

CAUTION: shared module-level stubs (`OriginImage`, `CacheProbe`, `CountingOriginImage`, the encoder-capability composites at `:735`) must move OUTSIDE the `for` (defined once) — they are `defmodule`s in the file body today. Also: per-arm cache isolation (spec) — any test using a stateful `CacheProbe` already creates a fresh ETS table per test, which the dual modules inherit independently; verify no test uses a NAMED shared table (grep `:named_table` in the file — if any, key the name by `@stack`).

- [ ] **Step 3: Run.** `mix test test/image_pipe/imgproxy_wire_conformance_test.exs` — expected: **298 tests** (149 × 2), PASS. Any dialect-arm failure is a real parity bug: fix the dialect (Tasks 7–18 modules), never the assertion. Budget for a debugging loop here — this is the integration gate the spec warned about.
- [ ] **Step 4: Re-home** the `:3881` `Imgproxy.encrypt_source_url/3` call: it is a test-side URL builder; point it at `ImagePipe.Parser.Imgproxy.encrypt_source_url/3` explicitly (it stays framework-owned in phase 1 — the dialect needs no URL-building helper).
- [ ] **Step 5: Gate + commit:** `git commit -m "Wire conformance dual-runs framework + dialect (149 x 2)"`

---

### Task 20: Dual-run differential

**Files:**
- Modify: `test/support/image_pipe/test/imgproxy_differential/harness.ex` (`plug_opts/0` → `plug_opts/1` taking `:framework | :dialect`)
- Modify: `test/image_pipe/imgproxy_differential_conformance_test.exs` (the generation macros loop over both arms)

**Interfaces:**
- `Harness.plug_opts(:framework)` = today's `Shared.plug_opts(ImagePipe.Parser.Imgproxy, @sources_dir)`; `Harness.plug_opts(:dialect)` = a new sibling in `Shared` (or local) doing `ImagePipe.Dialect.Imgproxy.init(sources: [...same RootHTTPAdapter wiring...])` with `render/2` calling `ImagePipe.Dialect.Imgproxy.call/2`. Keep `plug_opts/0` delegating to `plug_opts(:framework)` so `mix imgproxy.gen_report`/`diagnose` are untouched.
- Per-arm isolation: the differential harness uses no cache today (verify: `grep -n cache test/support/image_pipe/test/differential/harness.ex` — expected none) — nothing to isolate; state that in the commit message rather than adding machinery.

- [ ] **Step 1:** Extend the harness; loop the conformance test's case generation over `[:framework, :dialect]` with the arm in the test name.
- [ ] **Step 2: Run.** `mix test test/image_pipe/imgproxy_differential_conformance_test.exs` — expected: **(current per-constellation case count) × 2** plus the unchanged guard tests (the sources-hash/manifest drift tests do NOT dual-run — they check fixtures, not a stack). Count the cases first (`grep -cE '(c|lossy)\("' test/support/image_pipe/test/imgproxy_differential/constellations.ex`, ≈152 at plan-writing time) and record the actual doubled total in the commit message. PASS. **Never re-bake**; a dialect-arm failure is a dialect bug.
- [ ] **Step 3: Gate + commit:** `git commit -m "Differential conformance dual-runs framework + dialect (<actual count> x 2, no re-bake)"` (substitute the real per-arm case count from Step 2).

---

### Task 21: Cross-arm raw body-hash equality

**Files:**
- Create: `test/image_pipe/imgproxy_cross_arm_body_test.exs`

**Interfaces:** consumes Task 19's `translate_opts` pattern and Task 20's constellation URL builder (`Constellations.imgproxy_path/1`).

- [ ] **Step 1: Write the test:** over **all** constellations (both constellation constructors hardcode `verdict: :equal` — `constellations.ex:864,876` — so there is no verdict to filter on, and no nondeterminism marking exists). Expected outcome: no exclusions — in-process encoding is deterministic for equal inputs (the wire suite's own `resp_body ==` assertions rely on it). If a case nonetheless proves nondeterministic across arms, name it in an `@excluded` module attribute with a one-line reason (spec: "any exclusion must be named, not silently dropped") — likely candidates would be lossy `group:`-tagged AVIF cases, but none are expected:

```elixir
test "framework and dialect produce byte-identical bodies", %{} do
  for entry <- @equal_constellations do
    path = Constellations.imgproxy_path(entry)
    {fw_body, _} = render_via_framework(path)     # fresh Plug.init per arm
    {di_body, _} = render_via_dialect(path)       # independent init: per-arm isolation
    assert :crypto.hash(:sha256, fw_body) == :crypto.hash(:sha256, di_body),
           "cross-arm body divergence for #{entry.id} (#{path})"
  end
end
```

Each arm builds its own opts (no shared cache/state — spec §Per-arm cache isolation: the assertion's validity depends on each arm generating its own bytes).

- [ ] **Step 2: Run** — PASS. A mismatch is the strongest possible parity signal; bisect with `mix imgproxy.diagnose` conventions (differential README).
- [ ] **Step 3: Gate + commit:** `git commit -m "Cross-arm raw body-hash equality: dialect == framework, byte-exact"`

---

### Task 22: Contract kits

**Files:**
- Create: `test/image_pipe/dialect/imgproxy_contract_test.exs`

**Interfaces:** `use ImagePipe.ContractKit.CacheKey, dialect: ImagePipe.Dialect.Imgproxy` + `use ImagePipe.ContractKit.RequestSafety, dialect: ImagePipe.Dialect.Imgproxy`. The worked example is `test/image_pipe/dialect/native_contract_test.exs` — read it + both kits first; the kits may assume config-shape details (signing key format, sources) that need imgproxy-specific values.

- [ ] **Step 1: Implement the callbacks** with imgproxy paths (wire-suite URL shape — `plain/images/beach.jpg` relative sources against the kit's origin wiring, not `local:///`):
  - `equivalent_requests/1`: `["/unsafe/rs:fit:100:100/plain/images/beach.jpg", "/unsafe/w:100/h:100/rt:fit/plain/images/beach.jpg"]` (rs shorthand vs longhand — verify equivalence against the framework first with a quick wire probe); option order (`/unsafe/w:100/h:80/...` vs `/unsafe/h:80/w:100/...`); preset vs inline expansion.
  - `format_negotiation_cases/1`: mirror native's four buckets with imgproxy URLs (`f:webp` for explicit).
  - `storage_only_case/1`: a `cb:v1` vs `cb:v2` pair (cachebuster: differing keys, equal ETags — the kit asserts the split).
  - `rejectable_requests/1`: bad signature, malformed option (`rs:bogus:1:1`), oversized dimension — each with the kit's expected no-source-touch property.
  - `valid_request/1`: the plain fit URL.
- [ ] **Step 2: Run** `mix test test/image_pipe/dialect/imgproxy_contract_test.exs` — PASS.
- [ ] **Step 3: Gate + commit:** `git commit -m "Contract kits (CacheKey, RequestSafety) pass against Dialect.Imgproxy"`

---

### Task 23: Orientation matrix incl. auto-rotate-OFF (closes G1)

**Files:**
- Create: `test/image_pipe/dialect/imgproxy/orientation_matrix_test.exs`

**Interfaces:** the worked example is `test/image_pipe/dialect/native/orientation_matrix_test.exs` (27 tests) — read it in full; port its three invariants to imgproxy URLs, ADDING the auto-rotate-OFF arm native could not express.

- [ ] **Step 1: Port the matrix.** Cells: EXIF {1, 6, 8} × {`c:100:200:nowe:10:20` region-style crop, `rs:fill:150:100/g:fp:0.75:0.25`, plain `rs:fit:160:0`} × auto-rotate {on (`ar:1` or config default), **off** (`ar:0` — imgproxy's real option; check the grammar's spelling in `option_grammar.ex` — grep `auto_rotate`)}. Invariants per cell (native's three): (1) semantic op-kind sequence identical across storage orientations (auto-rotate-on arm only — with `ar:0` there IS no display-frame remap, assert instead that dims follow storage frame); (2) pixel invariance via the twin-oracle `PixelCompare` pattern (native's bound: exact dims + `fraction_over(…, 40) < 0.05`); (3) shrink correctness (decode shrink from storage dims, planning display-frame — native's EXIF-6 `w=300` worked example, `orientation_matrix_test.exs` shrink cell).
- [ ] **Step 2: Run** — PASS. Record in the test moduledoc: "closes probe gap G1 — the auto-rotate-OFF arm is exercised end-to-end for the first time."
- [ ] **Step 3: Gate + commit:** `git commit -m "Dialect.Imgproxy orientation matrix incl. auto-rotate-OFF arm (closes G1)"`

---

### Task 24: Error-path matrix + mount/path semantics

**Files:**
- Create: `test/image_pipe/dialect/imgproxy/error_paths_test.exs`, `test/image_pipe/dialect/imgproxy/mount_test.exs`

**Interfaces:** the worked example is `test/image_pipe/dialect/native_error_paths_test.exs` (9 rows) — read it in full and port each row to imgproxy URLs/config: (1) origin 5xx → 502 body `"upstream responded 503"`, sink never opened; (2) client disconnect during fetch (Coordinator owner-down — now `ImagePipe.Delivery.Coordinator`); (3) decode rejection → 415; (4) transform failure after partial work → 422, cleanup once; (5) encoder failure after first chunk → 200 committed, prefix only, sink aborted; (6) cache-lookup raise → 200 fail-open; (7) cache-write failure → 200 fail-open, abort not commit; (8) producer cancel; (9) response-already-sent. Mount tests (spec §Mount / path semantics): root mount, mount below a prefix (`Plug.Router` forward or a conn with `script_name` set — mirror how `path_test.exs` exercises `parser_request_path/1`), `/info` under a prefix, percent-encoded source bytes (`%2F` in a plain source), query string excluded from signed material (signed URL + `?x=y` still verifies).

- [ ] **Step 1: Port the 9 rows** (reuse the native test's stub plumbing — failing encoder stubs, raising cache adapters — which live in that file or its support modules; copy, don't import).
- [ ] **Step 2: Write the mount tests.**
- [ ] **Step 3: Run both files** — PASS.
- [ ] **Step 4: Gate + commit:** `git commit -m "Dialect.Imgproxy: 9-row error-path matrix + mount/path semantics tests"`

---

### Task 25: Telemetry contract test (both arms)

**Files:**
- Create: `test/image_pipe/imgproxy_telemetry_contract_test.exs`

**Interfaces:** spec §Telemetry equivalence. Scenarios: image cache miss, image cache hit, 304, `/info/`, streamed error after preparation, owner cancellation. Each scenario runs on BOTH arms (Task 19's dual-module pattern) with a unique private `telemetry_prefix`, attaching a handler forwarding to `self()` on the prefixed event names. Assert **stage names, ordering (start before stop, parse before source), and error stages** (`:result` metadata on failures). Do NOT assert PIDs, span counts, or process structure (a mechanism-coupled test would false-block the D3 gate — spec).

- [ ] **Step 1: Write** the six scenarios × two arms.
- [ ] **Step 2: Run** — PASS. If a stage name differs between arms, that is a real contract violation: fix the dialect's span naming (the dialect must emit the standard stage names — `[:request]`, `[:parse]`, `[:source, …]`, `[:transform, …]`, `[:encode, …]` — grep native's emissions for the canonical set).
- [ ] **Step 3: Gate + commit:** `git commit -m "Telemetry contract test: both arms, semantic assertions only"`

---

### Task 26: Docs sync, architecture test, full gates, exit-criteria cross-check

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (stage/order rows: stage 4 gains `Dialect.Imgproxy.Pipeline.run/4` alongside `Executor.execute/3`; stage 8's "reachable only through the imgproxy resolution strategy" adds the dialect's strategy-free `down: true` emission; scan every row naming `Resolver`/`PlanBuilder`: `grep -n "Resolver\|PlanBuilder\|resolution strategy" docs/imgproxy_support_matrix.md` and update each to name both stacks)
- Modify: `docs/imgproxy_path_api.md` (mount note: the dialect mounts directly — `plug ImagePipe.Dialect.Imgproxy, sources: […]` — vs the framework's `parser:` option)
- Modify: `test/image_pipe/architecture_boundary_test.exs` — add the `ImagePipe.Dialect.Imgproxy => "lib/image_pipe/dialect/imgproxy.ex"` map entry (follow `ImagePipe.Dialect.Native`'s at `:62`), `assert_boundary_deps` with Task 17's exact dep list, and `assert_boundary_exports(imgproxy_dialect, [ImagePipe.Dialect.Imgproxy.SourceScheme])`. The "no core file names a dialect" check: verify first whether the generic `ImagePipe.Dialect` prefix filter (`architecture_boundary_test.exs:258, 880`) already covers `Dialect.Imgproxy` — it filters by prefix, so it likely does; add an assertion only if a gap is demonstrated, not by rote (the `:610-622` region polices parser adapters, not dialects)
- Create: `.superpowers/sdd/phase1-exit-criteria.md`

- [ ] **Step 1: Docs sync** (all three files above).
- [ ] **Step 2: Architecture test** — run `mix test test/image_pipe/architecture_boundary_test.exs`, PASS.
- [ ] **Step 3: Full gates.**

```bash
export PATH="$(mise where elixir)/bin:$PATH"
mise run precommit
```

Expected: format, compile --warnings-as-errors, credo --strict, dialyzer, ExDNA, full `mix test` — ALL green. (If `.jxl` failures appear: rebuild vix per the memory note — `VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS`, not a source problem.)

- [ ] **Step 4: Exit-criteria cross-check.** Write `.superpowers/sdd/phase1-exit-criteria.md`: **all 13** of the spec's phase-1 exit criteria (numbered 1–13), each with its evidence (test file + count / commit / gate output). Criterion 9 records the D3 gate's actual outcome from Task 1/3. Any criterion not fully satisfied is listed as an explicit gap, never smoothed over (probe report's honesty contract).
- [ ] **Step 5: Commit:** `git commit -m "Docs sync + architecture boundary entry + phase-1 exit-criteria cross-check"`

**⛔ END OF PHASE 1. Do not start phase 2 (Parser.Imgproxy retirement) — it gets its own plan against the same spec.**

---

## Plan self-review notes (kept for the reviewer cycle)

- **Spec coverage:** D1 (copy) → Tasks 6, 10–13; D2 (dual-run) → 19–20; D3 (gated unification) → 1–3; D4 (phase split) → Task 26's stop marker; D5 (marker dies) → 8–9. Identity → 15; Errors → 16; chain → 17–18; every Testing-section item → 19–25; docs → 26; G1 → 23; G4 → 5+9; G5 recorded in 18.
- **Known sequencing risk:** Tasks 19–21 are the late integration gate the spec warns about; the unit-level nets (7–9, 15–16 tests) are the early defense. Budget debugging time at Task 19.
- **Deliberate deviations from the skill's letter:** copy tasks specify content by exact source file + named edits instead of inlining ~3,200 lines of grammar (transcription risk outweighs self-containment); Task 1/7 test skeletons show required assertions with arrange-code left to the implementer against named worked examples.

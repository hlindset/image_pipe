## Project guidelines

- `CLAUDE.md` is a symlink to this file — `AGENTS.md` and `CLAUDE.md` are the same file. Edit `AGENTS.md`. (If an editor tool reports `CLAUDE.md` as "not read yet" when you try to edit it after it was loaded as context, that's the symlink — read/edit `AGENTS.md` instead.)
- Use `mise exec -- ...` to run things in this repo with the correct versions of things
- Prefer the mise tasks for whole-repo workflows over invoking each tool by hand:
  - `mise run setup` installs the library and fiddle dependencies (`mix deps.get` for both, then `pnpm -C fiddle install --frozen-lockfile`).
  - `mise run precommit` runs the Elixir gate: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`. Run it before finishing broader changes.
  - `mise run precommit:fiddle` runs the Elixir gate plus the fiddle verify suite (the fiddle's Elixir checks + JS test/check/lint/format/build). Use it when a change also touches the `fiddle/` app.
- New worktrees auto-provision via Claude Code's `WorktreeCreate` hook (`scripts/worktree-create.sh`, wired in `.claude/settings.json`): it APFS copy-on-write clones `deps/` and `_build/` for both the root and `fiddle/` from the main checkout, then runs `mise trust` + `mise run setup`, so a fresh worktree skips the full recompile/refetch. The clone uses an OS-appropriate copy-on-write mechanism (`cp -c`/clonefile on macOS/APFS, `cp --reflink=auto` on Linux btrfs/XFS) and falls back to a plain copy otherwise; setup output is logged to `.worktree-setup.log` in the worktree (git-ignored). Dependency-setup failures are non-fatal — the worktree is still created.
- When an implementation is complete and you're ready to push to remote, first give the branch a proper descriptive name reflecting the work (e.g. `fix/native-extend-canvas-dpr`), instead of leaving it on the random name assigned by Claude or another agent harness (e.g. `claude/epic-lumiere-6fef7e`). Rename before the first push so the remote branch carries the meaningful name. Rename only the branch (`git branch -m <new-name>`); leave the worktree directory as-is — its name is local-only and never reaches the remote, and moving it (`git worktree move`) breaks the harness's exit-time cleanup.
- When a PR resolves issues, wire them to auto-close with **plain** closing keywords: one `Fixes #N` (or `Closes #N`) per issue, each as its own bare line in the PR body — e.g. `Fixes #236` then `Fixes #237`. GitHub does **not** parse a number range (`Fixes #236–#240`), a parenthetical/inline mention (`fixes the five issues (#236–#240)`), a comma list after a single keyword, or a bolded/heading-wrapped keyword — any of those leaves the issues open. Verify with `gh pr view <n> --json closingIssuesReferences`. Only add the keyword for issues the PR _fully_ resolves; reference a partially-addressed issue plainly (no keyword) so it stays open.
- This project is a greenfield, unreleased library; backwards compatibility should not be a concern at this point in time
- Prefer shrinking unsupported API surface over preserving tidy errors for bad internal callers. If a code path exists only to define behavior for impossible internal misuse, delete that behavior and its test instead of adding guards, fallbacks, or replacement tests.
- When you remove something — a line, comment, doc note, code path, option, list entry — remove it cleanly. Don't leave a stray note in its place that explains, justifies, or narrates the removal, restates what used to be there, or points out what something is _not_ (e.g. "X is no longer a span", "removed because…", or a parenthetical aside dangling after a trimmed list). The surrounding text should read as if the removed thing never existed; rationale for an edit belongs in the commit message, not the file.
- Match the process weight to the change. If a change is small and contained enough to hold in a single working context — a localized fix, a narrow option, an isolated edit with an obvious blast radius — skip the written spec/plan and do the design work interactively with the user, implemented test-first (TDD). Reserve written specs, implementation plans, and the plan-review cycle below for work that genuinely spans multiple contexts or whose design isn't settled. When unsure whether a change is small enough, lean toward asking the user rather than defaulting to heavyweight process.
- When presenting the inline-vs-subagent execution choice for a plan, lead with a calibrated recommendation rather than a neutral menu. Default to **inline execution + one final parallel review of the complete diff** when the plan's tasks are holdable in a single working context, and incremental TDD catches integration bugs faster than per-task review round-trips. Reserve **subagent-per-task with two-stage review** for plans whose tasks span many files or boundaries, or are large enough that context isolation per task earns its keep.

## API guidelines

- ImagePipe has one path-oriented, declarative API. Follow [the API contract](docs/api_contract.md) for capability retention, fixed stage order, coordinate frames, DPR, source concealment, and terminal semantics.
- Option order within a group must not define processing order. Only an explicit `then` opens a new group. Operations use the display frame produced by preceding stages; crop percentages resolve after trim. Deferred orientation is an implementation optimization and must preserve the logical result.
- Use one concrete request lifecycle and one executor. Keep host extension points for sources, caches, detectors, and exporters. Prefer direct calls and data over configurable dialect/parser/renderer behaviours, continuation protocols, and callback wrappers.
- Preserve useful capabilities identified in the contract before deleting their only entry point. Beads epic `image_plug-a0q` owns migration dependencies and progress.
- Keep selected imgproxy comparisons as test-only reference evidence for intentionally shared behavior. ImagePipe semantics govern disagreements; exact vendor parity is not required.
- When changing reference fixtures, follow `test/support/image_pipe/test/imgproxy_reference/README.md`. Update `SourceInventory` when adding, removing, or regenerating a source and check its consumers first: color-management tests also depend on source ICC profiles, bit depth, and alpha. Inspect generated-file changes with GitButler and retain only intentional fixture updates.

## Transform guidelines

- Keep transforms composable. Each operation expresses an image operation over `ImagePipe.Transform.State` with explicit parameters. The executor resolves source-dependent geometry and calls these operations directly.
- Trust operation structs inside the transform boundary. A transform struct missing required callbacks is a programmer error; validation should validate operation fields, not prove that the module implements the transform behaviour.
- Decode is always opened `:sequential`; random access is provided per-operation. `ImagePipe.Transform.DecodePlanner` no longer chooses an access mode — it always opens sequential and only computes the shrink/scale load option. The cost of random access is paid per-op, lazily, by `ImagePipe.Transform.run/3`, which materializes the image to RAM (`copy_memory`, via `ImagePipe.Transform.Materializer`, tracked by `State.materialized?`) immediately before the first operation that needs it. An operation declares its need with the `requires_materialization?/1` behaviour callback (default `false`); only operations that genuinely require arbitrary pixel access (smart/object-detect crop, trim, arbitrary-angle rotation) return `true`. EXIF auto-orient is the one self-managing exception, and is **not** a transform operation: it is carried as deferred `pending_orientation` state on `State` (`ImagePipe.Transform.PendingOrientation`) and applied late at the orientation-flush boundary (`ImagePipe.Transform.OrientationFlush`, after crop/resize with crop gravity + resize dimensions compensated into the storage frame), composing EXIF → user-rotate → user-flip (issue #146). Its materialization need is data-determined (the EXIF orientation header, which no op struct can see), so the flush self-materializes for EXIF orientations 3–8 (and any quarter/half-turn user rotate or vertical flip) and streams 1/2.
- Conservatism about sequential safety is preserved as a **test gate**, not a blanket random-access default. Before classifying an operation `requires_materialization?: false` (sequential-safe), it must be proven so by a per-op sequential-vs-random pixel-equivalence test opened from a genuinely streamed source (`access: :sequential`, `fail_on: :error` — not `from_binary`, which buffers) plus a property test over input shapes (sizes, orientations, sigmas); see `test/image_pipe/transform/sequential_access_test.exs`. The equivalence harness must include a self-check that a known-random op (e.g. a raw transpose) raises under the streamed open, so the comparison cannot pass tautologically. Materialization failures (`copy_memory`) are decode failures and must surface as `{:decode, _}` (→ 415), consistent between the mid-chain and delivery paths. The silent-buffering failure mode (libvips inserting a line/tile cache, yielding correct pixels but no memory win) is **not** covered by these correctness tests — it requires a memory high-water benchmark, currently deferred, so "no materialization" is a correctness-verified but not yet perf-verified claim.
- **Distinguish discretionary operations from input conditioning.** A concern that is (a) not a user-requested transform and (b) whose behavior is sourced entirely from runtime image inspection — the decoded image's own headers/interpretation/bytes, which _no operation struct can see_ — is **not** a transform operation. Model it as fixed pipeline preamble or self-managing `State`, the way decode access mode, shrink-on-load planning, EXIF auto-orient (`pending_orientation`), and input color-management (working-space import) already are. Its materialization need is governed by the same sequential-safety gate as any operation — prove it, don't assert it. The declarative knob a request _does_ control (e.g. the output color-profile policy) belongs on `Plan.Request.Output` and resolves into `Output.Policy`, not as a synthetic operation. EXIF auto-orient and input color management are the two worked examples.
- Keep the demo UI in sync with transform changes. When you add, remove, or change the parameters of a transform or a URL option, update the `fiddle/assets/` Svelte app (controls and URL state) in the same change so the demo can exercise the new behavior end-to-end.

## Request safety guidelines

- Preserve request safety boundaries: parse and config-validation failures should return before source fetch or cache access, source fetching should use non-bang Req flows with bounded redirects/timeouts/content-type/body limits, and decoded input pixel limits should remain explicit.

## Cache guidelines

- Cache only successful encoded responses, with deterministic keys; cache errors fail open (a fail-closed opt-in such as `fail_on_cache_error` is not currently implemented — adapters reject it as an unknown option). Which fields compose the key is owned by `ImagePipe.Representation` and its tests — read those rather than maintaining a field list here.
- The cache key and the ETag answer different questions; don't conflate their inputs. The **key** is storage identity: every input that can change the stored bytes or select a different stored variant, including the `storage_only` material (the cachebuster plus the request header/cookie values named by the mount's `storage_inputs`). The **ETag** is a strong byte-identity _validator_, deliberately narrower — it excludes the `storage_only` material, because changing a cachebuster or a vary-only input busts storage but yields byte-identical output and must not force a client to re-download identical content. Derive the ETag from request inputs (resolved source byte-identity seed + canonical request material + negotiated `Accept`), never from the stored output bytes: that is what lets a conditional GET return `304` before any source fetch, decode, encode, or cache read. Don't turn the ETag into a content hash of the body — it would regress that fast path.
- Neither the key nor the ETag is a generation gate. Keep safety limits (`max_body_bytes`, `max_input_pixels`, static result dimension limits) out of both: those decide whether a cache _miss_ may generate a response, not whether an existing successful cached response may be served.
- Greenfield: don't bump internal cache key data versions for normal feature work or cache-shape changes. Reshape the canonical key data and update tests in place unless the code must still read or preserve old cache entries.

## Telemetry guidelines

- Treat telemetry as part of the runtime observability contract. Use `:telemetry.span/3`-style `:start`, `:stop`, and `:exception` event naming for request and meaningful stage spans.
- Keep telemetry metadata safe by default. The real constraint is _sensitivity_ — not cardinality, and not whether a string looks path-shaped. Metadata fans out to every attached handler (including third-party exporters), so high-cardinality, product-neutral data is fine to emit: transform operation structs, decoded dimensions, class names, and identifiers like a detector's model-artifact name (e.g. a model filename) or a cache key. A value is not sensitive merely because it is a filename or path-derived — judge by whether the _specific_ value carries a secret or reveals private end-user content, not by its shape. (Separately, and for _boundary_ reasons rather than sensitivity: request-internal structs and cache-internal shapes should not leak into events — see the namespace guidelines.) What is _actually_ sensitive must not be emitted unless an explicit opt-in is designed and documented:
  - Secrets — signatures, tokens, credentials, API keys, or anything else that grants access.
  - Strings that routinely _embed_ such secrets — above all full source URLs and request paths, which commonly carry signed-URL query params, signature segments, or presigned credentials. Emit these only behind a documented opt-in, or after stripping the secret-bearing parts.
  - Private end-user content or PII the host would not want fanned out to exporters.
- Cardinality is a consumer concern, not an emission concern: `Telemetry.Metrics` requires the metrics author to choose tags, and nothing forwards the raw metadata map to storage. Emit the data; let handlers project it.
- Keep third-party backend integrations out of the library: hosts attach AppSignal, OpenTelemetry, and metrics handlers themselves. ImagePipe may ship an opt-in default handler that uses only the stdlib `Logger` (`ImagePipe.Telemetry.attach_default_logger/1`); it is never attached automatically. The one exception is an opt-in, optional-dependency OTel _exporter_ (`ImagePipe.Telemetry.Trace.OpenTelemetryExporter`) that ships adapter code only, compiles against `:opentelemetry_api` (optional), is never attached automatically, and uses only the public OTel API — the host still provides the SDK and configures the backend. Preserves "never automatic" and "no hard dep".
- Prefer shared telemetry helpers over ad hoc event emission so naming, measurements, metadata merging, and exception behavior stay consistent.
- Per-operation transform spans (`[:transform, :operation]`) are allowed for tracing execution structure (which operations ran, in what order). Their duration reflects pipeline _construction_, not pixel work — libvips is lazy — so never present per-operation duration as compute timing; keep honest aggregate timing on the coarse `[:transform, :execute]` stage span. Per-operation metadata carries the operation name (`:operation`), and may include the full operation struct (under the `:params` key) since it is derived from the public request and not sensitive; the default Logger shows the name and only dumps `:params` under `debug: true`.
- Keep the opt-in default Logger (`ImagePipe.Telemetry.Logger`) in sync with telemetry changes — the same way the demo UI tracks transform changes. When you add, remove, rename, or re-meta a telemetry event, update the Logger in the same change:
  - **Subscription.** A new event is invisible until it is added to `@group_span_events` (spans) or the one-shot lists (`@cache_oneshot`/`@transform_oneshot`). A renamed/removed event must be updated there too, or the Logger silently drops it or attaches to a dead name.
  - **Rendering.** Events with no specific `message/3` clause fall through to the generic clause, which prints `label` + `outcome(meta)` (i.e. `:result`). If you add a specific `message/3` clause, it **must still surface the outcome** — don't let a prettier message swallow `:result`/error state. Mind clause ordering: specific clauses come before the generic fallback.
  - **Levels.** If a new metadata value signals a failure/degradation, extend `level_for/3` (and `detect_fallback_warning?/2` for detection) so it escalates rather than logging at the base level.
  - **Coverage.** Add or update a `logger_test.exs` assertion for the new/changed line, and keep `docs/telemetry.md` aligned with both the events the Logger attaches to and what it renders.
- Keep the OTel trace exporter in sync with telemetry changes too — it is a **second, independent subscription surface** that the Logger sync rule above does not cover, and the two drift apart silently. `ImagePipe.Telemetry.Trace.OpenTelemetryExporter` does not subscribe directly; `ImagePipe.Telemetry.Trace.Capture` does, from two **static** lists: `@span_stages` (each gets `:start`/`:stop`/`:exception`) and `@oneshot_stages`. A new event is invisible to OTel until its stage is added there — an event present in the Logger's `@group_span_events`/one-shot lists is **not** automatically traced. When you add, remove, or rename a telemetry event, update both surfaces in the same change (Logger lists **and** Capture's `@span_stages`/`@oneshot_stages`), and cross-check that the two cover the same set so a stage isn't logged-but-not-traced (or vice versa). Beyond subscription, OTel span **attributes** are an allowlist: Capture's `@safe_keys` drops any metadata key not listed, so new non-sensitive metadata you want on the span must be added there (never add secret-bearing keys — see the sensitivity note in `capture.ex`). Add or update a Capture/exporter test asserting the new span/one-shot is captured, and keep the OTel side of `docs/telemetry.md` aligned.

## Namespace boundary guidelines

- Keep canonical request data under `ImagePipe.Plan.*`, with explicit groups and output policy.
- Keep URL parsing and request configuration together; parsing produces concrete data and validates static request constraints before side effects.
- Keep the mount interface and request orchestration under `ImagePipe.Plug`. Its lifecycle is parse, validate, source resolve, representation, conditional gate, cache, execution, and delivery.
- Keep source side effects and source identity under `ImagePipe.Source.*`.
- Keep response delivery under `ImagePipe.Response.*`.
- Keep output negotiation, format, policy, and encoding under `ImagePipe.Output.*`.
- Keep transform contracts, operation structs, execution state, runtime geometry, decode planning, and materialization under `ImagePipe.Transform.*`. The executor owns fixed operation ordering.
- Plug, source, and response code must call the transform facade rather than concrete operation modules. Keep boundary exports narrow: behaviours at real host extension points and concrete entry points elsewhere.

## Boundary library guidelines

- Use `Boundary` declarations to enforce namespace ownership. Update declarations and architecture tests together as modules move.
- The Plug lifecycle may depend on parsing/configuration and the core facades it orchestrates: source, cache, representation, decode, transform, output, response, delivery, telemetry, and error handling.
- Parsing depends on canonical plan data. Runtime geometry belongs to the executor, which must not depend on URL grammar, Plug, source fetching, cache storage, output encoding, or response delivery.
- Source code must not depend on cache, response, or request orchestration. Cache may depend on canonical identity/output/transform material. Output may depend on canonical output intent, but not request parsing.
- Move shared value types to their actual owner as consumers migrate. Do not preserve a generic dispatch framework to retain its structs.
- Export only concrete entry points and host contracts. Do not export implementation helpers merely to satisfy a compile error.
- Keep architecture tests focused on dependency direction, source/response isolation, and orchestration avoiding concrete image operations.

## Elixir architecture guidelines

- Prefer Elixir extension points with explicit behaviours (`ImagePipe.Source`, `ImagePipe.Transform.Detector`, `ImagePipe.Cache`), `@impl` annotations, typed parameter structs, and tagged `{:ok, value}` / `{:error, reason}` returns at runtime boundaries. Reserve raises for invalid initialization/configuration.
- Validate public options explicitly, preferably with `NimbleOptions` or adapter-owned `validate_options/1`, and reject unknown or malformed options before side effects.
- For trusted internal behaviour dispatch, call the callback directly and let missing callbacks raise. Do not add runtime duck-typing probes, callback-presence checks, or wrapper functions whose only purpose is to make impossible internal misuse return tidy errors.
- Constructor APIs should accept the narrowest shape that real callers use. Do not accept both keyword lists and maps, existing structs, or negative guard carve-outs such as `is_map(value) and not is_struct(value)` unless there is a real public caller or contract requiring it.
- Use pattern matching, small private functions, and `with`/`case` pipelines to keep success paths linear while preserving precise error tags. Avoid catch-all rescues unless a concrete runtime boundary intentionally degrades to a documented safe default; do not rescue trusted transform callback failures.

## Validation guidelines

Validation belongs at boundaries the caller doesn't control. Inside the codebase, trust what another module just produced.

**Validate:**

- Host configuration and option parsing (mount options, request config, adapter config).
- HTTP request input (headers, query strings, bodies, conditional-request fields).
- Cache reads from external storage and other data crossing a serialization boundary.
- Third-party API responses.
- Return values from host-implementable behaviours such as `ImagePipe.Source`, `ImagePipe.Transform.Detector`, and `ImagePipe.Cache` adapters.

**Don't validate:**

- Struct fields already guaranteed by `@enforce_keys` (the struct can't exist without them).
- Values another module in this codebase just constructed and handed you.
- Properties a structural check can't actually prove (determinism, semantic stability, secret-freeness). Document the contract in `@moduledoc`/`@doc` and assert it in producer tests instead.
- Hypothetical future callers that don't exist yet — add the validation when the future caller appears, with a test that exercises it.

**Rule of thumb:** if tempted to add a guard, ask whether the value's producer is in this repo. If yes, write a test against the producer instead. If no, validate at the boundary where the value enters.

**Removing a guard at a real boundary counts as a behavior change.** Justify with a producer test or an unreachable-from-callers analysis, not "it looks unused".

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you _must_ bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Avoid** nesting multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist.
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mise exec -- mix help task_name`)
- To debug test failures, run tests in a specific file with `mise exec -- mix test test/my_test.exs` or run all previously failed tests with `mise exec -- mix test --failed`
- Run `mise exec -- mix credo --strict` to lint the codebase.
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
- Before finishing code changes, run the relevant focused tests through `mise exec -- ...`; for broader behavioral or public API changes, also run `mise exec -- mix test` and `mise exec -- mix compile --warnings-as-errors`.

## Test guidelines

### When to add tests

- For behavior changes, add focused ExUnit coverage at the relevant boundary: grammar/order-insensitivity and execution, mount-level no-source-fetch failures, output negotiation including `Vary: Accept`, cache key/corruption behavior, and source/decode limit handling.
- Add a compact set of wire-level Plug tests when changing request parsing, execution, output negotiation, caching, or safety behavior. These tests should make real `ImagePipe.Plug.call/2` requests and assert user-visible contracts such as status, headers, content type, decoded output dimensions, cache/source access, and response-body equivalence where relevant.
- When a request option should visibly change image pixels, include a request-boundary test that decodes the response body and compares pixels against a plain or otherwise appropriate baseline. Cover the no-geometry form separately when the option must work without resize, crop, canvas, or padding. Request structs and transform-unit assertions are not enough for these changes.
- Keep wire-level tests representative, not exhaustive. Use them for public contracts such as option-order equivalence, `Accept` negotiation and `Vary`, explicit output formats bypassing negotiation, representative geometry results, request-safety failures before source/cache access, and cache reuse for semantically equivalent requests. Leave grammar edge cases and combinatorial coverage in parse, execution, cache-key, and property tests.
- Add StreamData property tests when correctness depends on invariants across many input shapes or orderings, such as canonicalization, filesystem safety, option order-insensitivity, cache keys, normalization, and round-trip behavior. Keep focused example tests for specific edge cases and error messages.

### Tests not to write

**Rule of thumb:** before writing a test, ask whether a real producer in this repo can construct the input you are about to assert on. If no in-repo producer creates that shape, you are testing impossible misuse — delete the production code path instead of pinning it with a test. Tests follow the same boundary discipline as validation (see _Elixir architecture guidelines_): assert at boundaries the caller doesn't control, trust what another module in this codebase just produced.

- **No impossible-internal-misuse tests.** Do not hand-build internal structs (request structs, transform operations, cache entries) that no real producer in this codebase constructs, just to assert that a validator rejects them or that a negative guard branch fires. Hand-built `%ImagePipe.Transform.Operation.Resize{}` or request-internal struct literals outside that request module's own test files are a strong signal.
- **No name- or existence-policing tests.** Do not assert that a module exists, that a function is exported (`function_exported?/3`, `Code.ensure_loaded?/1`), or that a stale module remains deleted. If a real caller needs the function, that caller's test already exercises it; if no real caller exists, the test is policing a name.
- **No post-migration parity pins.** After a rename or refactor lands, delete the parity, characterization, and "old vs new" tests added to pin it during the transition. Keep them only if they cover behavior no other test asserts. Files named `*_characterization_test.exs` in this greenfield codebase are a smell — they usually mean the refactor is done and the pin has lost its purpose.
- **No private-implementation tests.** Do not assert on exact private validation error strings, bang vs non-bang spellings, or other private helper choices. Test the runtime contract, not the implementation path that satisfies it.
- **No source-text scanning outside architecture tests.** Reading `.ex` files to grep for forbidden references is allowed only in `test/image_pipe/architecture_boundary_test.exs`, and only to enforce namespace boundaries (e.g. the runner must not name concrete transform modules, and transform code must not depend on URL parsing). Anywhere else, source scanning is a smell.

### Process discipline

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

- **Scope telemetry assertions with a private `telemetry_prefix`.** `:telemetry` handlers are global and fire for every emission of an event name VM-wide, regardless of which process emitted it. In an `async: true` test that attaches a handler on a default-prefix event (e.g. `[:image_pipe, :output, :clamp]`) and forwards to `self()`, a _different_ module running concurrently can emit that same event and leak it into this test's mailbox — silently satisfying an `assert_received` or flaking a `refute_received`. So any test that asserts/refutes on a telemetry message must pass a unique `telemetry_prefix` in the request opts and attach/match on the prefixed event name, never the default `[:image_pipe, …]` name. Existing examples live in `test/image_pipe/api/info_wire_test.exs` and `test/image_pipe/api/color_management_wire_test.exs`.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->

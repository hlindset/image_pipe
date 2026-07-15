# D3 topology audit report — `Request.SourceSession` supervision gate

**Purpose.** Per the spec (`docs/superpowers/plans/2026-07-15-imgproxy-dialect-inversion-phase1.md`
and `docs/superpowers/specs/2026-07-15-imgproxy-dialect-inversion-design.md`,
"D3 in detail — the topology audit gate"), `ImagePipe.Request.SourceSession`
migrates from its current `DynamicSupervisor`-supervised topology
(`ImagePipe.Request.SourceSessionSupervisor`, a child of `ImagePipe.Supervisor`
in `lib/application.ex:26`) to a monitor-owned primitive (`ImagePipe.Delivery`,
generalizing the pattern already shipped for the native dialect as
`ImagePipe.Dialect.Native.Delivery.Coordinator`) **only if** a pre-implementation
audit confirms the supervisor provides no supported host extension point,
required admission control, meaningful restart recovery, or shutdown guarantee
the monitor-owned primitive cannot preserve.

This report re-verifies the spec's audit table against the current source (not
the spec's own citations, taken on faith) and resolves the one item the spec
marks **OPEN**: application-tree shutdown. Task 1's characterization tests
(`test/image_pipe/request/delivery_owner_cleanup_baseline_test.exs`,
`test/image_pipe/request/source_session_app_shutdown_characterization_test.exs`,
`test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs`) back the
findings below with passing, green-against-the-untouched-topology tests.

---

## 1. Restart recovery — re-verified PASS

**Claim:** supervision supplies no restart recovery for a `SourceSession`.

**Evidence:**
- `lib/image_pipe/request/source_session.ex:55` — the `child_spec/1` sets
  `restart: :temporary`:
  ```elixir
  restart: :temporary,
  ```
- `test/image_pipe/request/source_session_supervisor_test.exs:215` — the test
  `"temporary sessions are not restarted after a crash before prepare"` kills a
  session with `Process.exit(session, :kill)` and asserts the supervisor's
  child count returns to `active: 0, workers: 0` (no restart attempt) and that
  the dead session is unreachable (`{:error, {:session, :noproc}}` from a
  subsequent call).

**Verdict: confirmed.** A `:temporary` child is never restarted by its
supervisor regardless of exit reason — the supervisor's only role is
bookkeeping (start / track / stop-on-command), not recovery. A monitor-owned
process with no restart policy at all is behaviorally identical here.

## 2. Admission / concurrency policy — re-verified PASS

**Claim:** the supervisor enforces no admission or concurrency control.

**Evidence:** `lib/image_pipe/request/source_session_supervisor.ex:45-48`:
```elixir
@impl DynamicSupervisor
def init(_opts) do
  DynamicSupervisor.init(strategy: :one_for_one)
end
```
No `:max_children` (defaults to `:infinity`), no `:max_restarts`/`:max_seconds`
tuning, no custom `start_child` gating. `start_session/3`
(`source_session_supervisor.ex:30-34`) forwards directly to
`DynamicSupervisor.start_child/2` with no queueing or rejection logic.

**Verdict: confirmed.** There is no admission policy to lose. A host wanting
concurrency limits today would have to implement it externally (e.g. a rate
limiter in front of the plug); nothing about removing the `DynamicSupervisor`
changes that surface.

## 3. Host-visible API surface — re-verified PASS (doc-sync item only)

**Claim:** `SourceSession`/`SourceSessionSupervisor` have no public,
host-facing documentation; the only doc mention is explanatory.

**Evidence:**
- Both modules carry `@moduledoc false`
  (`source_session.ex:2`, `source_session_supervisor.ex:2`) and live under
  `ImagePipe.Request.*`, a boundary namespace this design dissolves for the
  dialect-owned pipelines.
- A repo-wide search of `docs/*.md` and `README.md` for `SourceSession` /
  `SourceSessionSupervisor` finds **exactly one hit**:
  `docs/telemetry.md:855-861`, inside the "Tracing (opt-in)" section, describing
  how the span tracer reconstructs parentage "across the request →
  `SourceSession` → `Producer` process seams". This is explanatory prose about
  an implementation detail of trace reconstruction, not API reference — it
  documents no public function, no configuration option, no supported
  extension point of `SourceSession` itself.

**Verdict: confirmed**, and narrower than the spec table even states: there is
no *other* doc reference at all, not just no *API* reference. This is a
doc-sync item for Task 3 (the process-seam description at
`docs/telemetry.md:860` needs to describe the new topology), not a blocker.

## 4. Ownership / failure propagation — not re-audited here (out of scope for Task 1)

The spec cites the probe's 9-row error matrix for the monitor topology as
covering this. Re-verifying that matrix was not in this task's brief; it is
listed here for completeness of the spec's table, not independently checked.

## 5. Cancellation latency — not re-audited here (out of scope for Task 1)

Spec: "force-kill → graceful halt + ~1s backstop (G6)", already scoped as a
known, accepted behavior delta. Not re-checked by this task.

---

## 6. Application-tree shutdown — the OPEN item, characterized (supervisor-stop arm) + inferred (app-stop chain)

This is the one row the spec marks **OPEN**. The spec's sequencing rule
requires the guarantee to be **proven by a test, not inferred** — Baseline B
does that for the *supervisor-stop* arm specifically (§6a, §6c): it drives a
real `SourceSessionSupervisor` and a real `Supervisor.stop/2`. It does not,
and cannot without actually invoking `Application.stop(:image_plug)`, prove
that the same guarantee holds for the full application-shutdown chain —
`Application.stop` → `ImagePipe.Supervisor` → `SourceSessionSupervisor`. That
link rests on the child-spec at `lib/application.ex:26` (`SourceSessionSupervisor`
is listed as a direct child of `ImagePipe.Supervisor`, which `Application.stop`
tears down transitively per standard OTP supervision semantics) and is an
**inference**, not a characterization. The inference is sound — it is simply
not what the test asserts, and should not be described as "proven by test."

### 6a. What the current (supervised) topology actually guarantees

`test/image_pipe/request/source_session_supervisor_test.exs:134`,
`"supervisor shutdown is parent shutdown, not request owner death"`, pins that
stopping the `SourceSessionSupervisor` (`Supervisor.stop(supervisor, :shutdown)`)
terminates an in-flight `SourceSession` with reason `:shutdown` — a *different*
code path from owner death (which terminates with
`{:shutdown, {:owner_down, reason}}`).

Task 1's Baseline B
(`test/image_pipe/request/source_session_app_shutdown_characterization_test.exs`)
re-confirms this under an `start_supervised!`-wrapped "app-tree" shape and
additionally establishes a fact the spec's table does not surface: **this
shutdown path is exactly as forceful/ungraceful as owner death, not more
graceful.** `SourceSession.terminate/2` → `stop_producer/2`
(`source_session.ex:387-390`) hard-kills the producer with
`Process.exit(producer, :shutdown)` on *both* the owner-death path and the
app-tree-shutdown path. This does **not** invoke a `Stream.resource/3` `after`
callback — verified empirically in this task (a `Stream.resource`-based
`image_module` stub's `after` never fires when the process holding its
continuation is killed, confirmed by direct experiment, not merely asserted).
The only reliably-observable "cleanup happened" signal on either forced-
termination path is the `[:cache, :stage]` telemetry event
(`ImagePipe.Cache.Sink.abort/3` → `cache: :stage_abandoned`), which is why both
Baseline A and Baseline B use it as their exactly-once observation point.

**Correction to how the spec's "plausibly the same outcome" framing might be
read:** *within the current supervised topology*, the delta between its two
forced-termination arms (owner-death and app-tree shutdown) is not
*gracefulness* — both are equally forceful today, as shown above. That much of
the original correction stands.

This does **not** mean gracefulness is a non-issue for the migration as a
whole — only that it is not what distinguishes the two arms *today*. The
*target* monitor topology changes the termination mechanism itself:
`ImagePipe.Dialect.Native.Delivery.Coordinator` — the shipped model for
`ImagePipe.Delivery` — "ALWAYS requests a graceful halt first
(`Producer.request_halt/2`), backstopped by a timeout that force-kills a
wedged producer" (`coordinator.ex:56-59`; rationale at `coordinator.ex:1-27`'s
moduledoc: a forceful kill would skip the producer's `try/after` bracket
cleanup, breaking the cleanup-runs-exactly-once invariant on owner disconnect,
not just on explicit cancel). So migrating **does** convert force-kill to
graceful-halt-with-backstop on the owner-death arm (and would on an app-tree
arm, if one existed post-migration) — a second delta, orthogonal to the one
above. This is not new information: §5 already scopes it as "force-kill →
graceful halt + ~1s backstop (G6) … a known, accepted behavior delta." The
two deltas should not be conflated:

- **Gracefulness of the termination mechanism** (force-kill vs.
  graceful-halt-with-backstop) — a *current-vs-target* delta, already flagged
  and accepted in §5/G6. Not re-litigated by this section.
- **Scope / reachability of app-tree shutdown** (whether a delivery is
  reachable from `:image_plug`'s supervision tree at all, independent of
  owner liveness) — the actual OPEN item this section (§6b onward) resolves.

Neither delta changes the other's status, and neither changes §8's
recommendation: that recommendation rests on findings 1–3, finding 6's narrow
scope, and the native-dialect precedent (§8 points 1–3) — none of which turn
on the gracefulness question, which was already priced in as an accepted
delta before this correction and remains so after it.

### 6b. What changes under the monitor topology

`ImagePipe.Dialect.Native.Delivery.Coordinator` — the shipped, in-production
model for the target primitive — states this explicitly in a comment directly
above its `start/4` entry point (`coordinator.ex:56-59`; not the moduledoc,
which is the bracket-cleanup note quoted just above):

> "No OTP supervisor and no link to the caller — the coordinator is reached
> only via `Process.monitor/1` in both directions... `GenServer.start/2` (not
> `start_link/2`) is deliberate."

Confirmed at the call site: `lib/image_pipe/dialect/native/delivery.ex:88` —
`Coordinator.start(build_fun, conn_owner_pid, ...)` — with no supervisor
involved anywhere in the call chain. This is **already the case today, in
production, for the native dialect.**

**The finding requiring a ruling:** post-migration, nothing in `:image_plug`'s
application tree supervises delivery processes. `Application.stop(:image_plug)`
today stops `ImagePipe.Supervisor`, which stops its child
`SourceSessionSupervisor`, which — regardless of whether each in-flight
delivery's *owner* (the host's connection-handling process) is alive or dead —
terminates every in-flight `SourceSession` as a supervision-tree side effect.
Under the monitor topology, `Application.stop(:image_plug)` does nothing to an
in-flight delivery whose owner is still alive: the delivery process is not
part of `:image_plug`'s supervision tree at all, and terminates **only** when
its owner eventually dies (for whatever reason, on whatever schedule the host's
own supervision tree — Bandit/Cowboy/Phoenix.Endpoint, entirely outside
`:image_plug` — decides). The shipped native dialect already has exactly this
property today: stopping `:image_plug` does not touch an in-flight native
delivery whose host connection process is still alive.

Whether this is a real behavior regression depends entirely on whether any
host relies on `Application.stop(:image_plug)` (or the app being torn down as
part of a supervisor restart, a release upgrade, etc.) to bound in-flight
delivery lifetime independent of the host's own connection lifecycle. No such
reliance is documented anywhere (see finding 3 above — there is no host-facing
doc for `SourceSession` at all), and none of the framework's own tests assert
on this property from outside the `Request.*` boundary. But "undocumented"
is not the same as "provably unused by every real host" — this is a genuine
behavior change, not a paperwork gap, and is why the spec correctly gates
Extraction A on it rather than waving it through as another "Pass" row.

### 6c. Test evidence

Both baselines are now green against the **untouched, current supervised
topology**, per the spec's required sequencing ("characterization-then-preserve,
not red-green"):

- **Baseline A** (`delivery_owner_cleanup_baseline_test.exs`) — topology-neutral,
  observed entirely through the public `ImagePipe.Plug` surface, names no
  `SourceSession*` module. Must pass **unmodified** after Task 3; a changed
  assertion there is a gate failure by the spec's own rule.
- **Baseline B** (`source_session_app_shutdown_characterization_test.exs`) —
  mechanism-coupled (calls `SourceSessionSupervisor`/`SourceSession` directly,
  stops the `DynamicSupervisor`). Cannot survive the migration unmodified by
  construction; its fate is exactly what this checkpoint decides (§7 below).
- **OTel parentage baseline** (`delivery_span_parentage_baseline_test.exs`) —
  asserts, on a real cache-miss streamed request, that the
  `[:source, :fetch_decode]`, `[:transform, :execute]`, `[:encode]`,
  `[:cache, :write]`, and `[:deliver]` stage spans are transitive descendants
  (not merely direct children — `[:deliver]` is a two-hop descendant, nested
  under `[:send]`) of the `[:request]` root span, by trace_id and a
  `parent_span_id` chain walk. Semantics only: no PIDs, no span counts, no
  process-hop assertions, so a topology change cannot trivially satisfy or
  trivially break it by accident.

All three pass on the current codebase:

```
mix test test/image_pipe/request/delivery_owner_cleanup_baseline_test.exs \
         test/image_pipe/request/source_session_app_shutdown_characterization_test.exs \
         test/image_pipe/telemetry/delivery_span_parentage_baseline_test.exs
# Result: 3 passed
```

---

## 7. Gate outcomes

**Outcome A — Proceed.** The user rules the app-tree-shutdown-independent-of-
owner-liveness guarantee **out of contract** (no host may rely on
`Application.stop(:image_plug)` bounding in-flight-delivery lifetime
independent of the host's own connection lifecycle — consistent with there
being zero host-facing documentation of any such guarantee today, finding 3).
Task 3 proceeds: `Request.SourceSession` migrates to the monitor-owned
`ImagePipe.Delivery` primitive, `SourceSessionSupervisor` and its
`lib/application.ex:26` child entry are deleted, Baseline A and the OTel
parentage baseline are kept and must pass unmodified against the new topology,
and Baseline B is deleted with this ruling cited in the deletion commit
message (per this task's brief: "deleted because the user ruled the app-tree
arm out of contract").

**Outcome B — Dialects-only.** The user rules the guarantee **in contract**.
Because the monitor topology structurally cannot preserve app-tree-shutdown
reach over an owner-still-alive delivery (§6b — this is not a bug to fix, it
is the topology's defining property), this ruling selects the dialects-only
branch by construction: Extraction A is limited to `Dialect.Native` and
`Dialect.Imgproxy`, `Request.SourceSession`/`SourceSessionSupervisor` stay
exactly as they are today (still backing the framework's `Parser.Imgproxy`
path per D2's dual-run), and Baseline B is **kept** (not deleted) as the
now-permanent characterization of the guarantee that blocked full unification.

## 8. Recommendation

**Recommend Outcome A — proceed.** Reasoning:

1. Findings 1–3 are unambiguous passes, re-verified independently in this
   report against current source, not merely re-cited from the spec.
2. Finding 6's gap is real but narrow: it only matters for a host that (a)
   calls `Application.stop(:image_plug)` (or triggers an equivalent app-tree
   teardown) independently of stopping its own connection-handling processes,
   AND (b) relies on that action bounding in-flight delivery lifetime. This is
   an unusual and undocumented operational pattern — normal deployment
   (release stop, node shutdown, supervisor restart of the whole release) tears
   down the host's connection processes together with `:image_plug`'s, at
   which point owner-death cleanup (Baseline A's guarantee, preserved
   identically) fires regardless of which topology is in place.
3. The monitor topology's app-tree-independence is not new or experimental —
   it is the **already-shipped, in-production behavior of the native dialect**
   (`Dialect.Native.Delivery.Coordinator`). Choosing Outcome A means the
   framework's remaining `Parser.Imgproxy`/`Request.SourceSession` path
   converges onto a shutdown behavior the codebase already ships and has
   presumably not seen host complaints about.
4. Outcome B does not remove the risk, it just leaves two different shutdown
   behaviors live in the codebase simultaneously (native dialect: monitor-only;
   framework: app-tree-reachable) indefinitely, which is itself a
   documentation and reasoning burden, for a guarantee finding 3 shows no host
   currently depends on being told about.

This recommendation is not binding — per the spec and this task's brief, the
user's ruling is what decides both whether Task 3 runs and Baseline B's fate.

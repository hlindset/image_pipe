# OTP failure modes, round 1

Scope: supervision trees and restart strategies in `image_pipe` and `image_pipe_server`, what happens when each long-lived process crashes or restarts, timeouts and caller cleanup, mailbox growth, monitors, and shutdown and startup ordering. Read on `main` at `6a87579`. Paths are relative to `image_pipe/` unless they start with `image_pipe_server/`.

**How this was checked.** *Confirmed* means reproduced by fault injection in a throwaway ExUnit file (`otp_probe_test.exs`, kept beside this report in the project files, not committed to the repo). *By reading* means it wasn't run.

**Dedupe.** Checked against the section titles of every earlier `bug-hunt-*`, `perf-review-*`, `memory-leak-hunt` and `simplification-1` report, and in detail against `bug-hunt-6/sources-and-caching.md` (source lock, admission split) and `bug-hunt-4/image-processing-and-output.md` #6 (detector warmup retries, now fixed with unbounded backoff). The Admission mailbox risk raised in `memory-leak-hunt/report.md` is not repeated here.

Counts: 1 medium, 1 medium-low, 6 low.

---

## 1. A child that crash-loops takes the whole instance down within milliseconds

- **Severity:** medium (library hosts; the server can't hit the trigger below)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/instance.ex:173-180` (one `:one_for_one` supervisor with the default 3 restarts in 5 s for the pool, caches, publisher and warmup), `lib/image_pipe/transform/detector/warmup.ex:25` (`restart: :transient`), `lib/image_pipe/transform/detector.ex:165-169` (calls the host's `warmup/1` unprotected), `lib/image_pipe/config.ex:759-761` (`raise ArgumentError, "... is not running"`)

**Evidence.** An instance with a custom detector whose `warmup/1` raises (a host extension point; the AGENTS.md validation rules count it as a boundary). The warmup GenServer crashes in `handle_continue`, is restarted as `:transient`, crashes again, and after 4 attempts the instance supervisor gives up:

```
T2 warmup attempts: 4
T2 instance down (reason, ms): {:shutdown, 15}      (75 ms on another run)
T2 request while instance is down: {503, "image processing unavailable"}
T2 again: {:raised, ArgumentError, "ImagePipe instance OtpProbe.Test.T267 is not running"}
```

So a detector that can't reach its model server stops the processing pool, both caches (their Writers abort in-flight writes) and the publisher. Every request then raises out of `ImagePipe.Plug.call/2` (a 500 with a crash report each), and the exit goes on to the host's supervisor, which restarts the instance into the same loop and then exceeds its own limit. In a release, where the host app is permanent, that stops the node.

The same budget is shared by everything else under the instance: a Root that restarts on an ownership takeover, a Root whose cache supervisor gave up, the pool. Three of those in 5 s for unrelated reasons also take the instance down.

**Suggested fix.**
1. In `Warmup`, run the callback under `try` and treat a raise or exit as `{:error, {:raised, kind}}` with the existing backoff, so a failing warmup never crashes its process. Do the same for `available?/1`, which `handle_continue` also calls.
2. Consider answering a request for an instance that isn't running with a 503 (`{:processing, :unavailable}`-style) instead of raising, since the window between an instance stopping and restarting is normal.

**Question for Håvard:** do you want the instance's restart budget raised (or the warmup moved out from under it), or is "a broken detector stops the instance" acceptable once the warmup can't crash?

---

## 2. After Admission or Writers restarts, the cache's periodic sweep is gone for good

- **Severity:** medium-low (leftover temp files, pins and unnamed bodies stop being removed until the node restarts)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/file_system/store.ex:71-79` (`[Registry, Admission, Writers, PeriodicSweep]` under `:rest_for_one`), `lib/image_pipe/cache/file_system/periodic_sweep.ex:13-18` (`restart: :temporary`)

**Evidence.** OTP never restarts a `:temporary` child, even when `:rest_for_one` terminates it because an earlier sibling died. Killing Admission:

```
T1 cache children before: [{Sweep, ".../cache"}, Writers, {Admission, ".../cache"}, Registry...]
T1 cache children after Admission restart: [Writers, {Admission, ".../cache"}, Registry...]
```

The new Admission's startup scan sweeps once, then nothing sweeps that root again. The module's comment ("A sweep that crashes stops the repeats") covers a sweep's own crash, not a sibling's. A Writers crash has the same effect.

**Suggested fix.** Make the periodic sweep `:transient` (a sweep that raises still stops, as documented, if it then exits `:normal`; or catch inside `handle_info(:sweep, …)` and keep the timer), or move it before Admission and give it its own failure handling. Test: kill Admission and assert the sweep child is back.

---

## 3. A streamed request whose coordinator dies without its `terminate` holds a pool slot forever

- **Severity:** low (needs a `:kill` or a crash in `terminate`; the leak is permanent)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/processing_pool.ex:386-390`, `:571-572` (owner `DOWN` on an active job only sets `result: :cancelled`), `:377` (the deadline timer only acts when `result: nil`), `lib/image_pipe/delivery/producer.ex:104-123` (`pump_loop/1` waits for `:next`/`:halt` with no timeout and doesn't watch the coordinator), `lib/image_pipe/processing_pool.ex:205` (`acquire` unlinks the producer from the coordinator)

**Evidence.** Pool with `max_concurrency: 1, processing_timeout: 300`. Prepare a two-chunk `Delivery.stream`, then `Process.exit(coordinator, :kill)`:

```
T4 pool 1 s after the coordinator died (deadline 300 ms): %{active: 1, queued: 0, ...}
T4 next request: {:error, {:processing, :overloaded}}
```

The producer sits in `pump_loop` forever, holding the slot and the encoder. The pool saw the owner die but only marked the job cancelled, which also turns off its processing deadline, so nothing ever reclaims it. Every graceful exit path in the coordinator sends `:halt` first, so in practice this needs a `:kill` (the coordinator traps exits and ignores any other exit signal) or a raise inside its `terminate/2` before `stop_producer`.

**Suggested fix.** Either have the producer monitor its coordinator and halt the stream on `DOWN`, or have the pool forward an owner `DOWN` for an active job to the worker (it already knows `job.worker`), so the worker halts. Keeping the deadline active for cancelled jobs would at least bound it.

---

## 4. A writer's shutdown drain never runs on a real shutdown

- **Severity:** low (dead code; a write whose commit lands during a shutdown is dropped, as it would be without the drain)
- **Confidence:** confirmed
- **Where:** `lib/image_pipe/cache/writer.ex` `handle_info({:EXIT, _pid, reason}, state)` and `drain/1` (the "A shutdown finishes a write whose chunks and commit already arrived" comment), `test/image_pipe/cache/writer_test.exs:161-176`

**Evidence.** `gen_server` handles an `{'EXIT', Parent, Reason}` from its own supervisor itself and calls `terminate/2` directly; `handle_info` only sees exits from other linked processes, and the writer has none. The existing test sends the exit from the test process, which is why it reaches `handle_info`. Same writer state (exit, then a chunk and the commit queued behind it), two senders:

```
T3 exit from a non-parent (as writer_test does): {:shutdown, :hit}
T3 exit from the Writers supervisor (a real shutdown): {:shutdown, :miss}
```

(A suspended process also handles its parent's exit at once, so the probe keeps the writer busy with `:sys.replace_state` instead of `:sys.suspend`.)

**Suggested fix.** Decide whether the drain is wanted. If not, delete the `{:EXIT, …}` clause and `drain/1`, and the `Owner.refused?` check with them (FIFO already finishes a commit that arrived before the shutdown). If it is, do it in `terminate/2`, which does run for the parent's exit. Either way, make the test send the exit from the real `Writers` supervisor.

---

## 5. A PinnedPools restart orphans every pinned Finch pool

- **Severity:** low (needs a crash; then a slow leak of pools and sockets)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/source/http/pinned_pools.ex:72-84` (the ETS table and the retired list live in the GenServer), `:31-48` (`generation/1` reads the table from the request), `:87-110` (sweep calls `Finch.get_pool_status/2` and `Finch.stop_pool/2` synchronously)

**Evidence.** The table of generations is owned by the GenServer, and the list of retired pools is its state. If it crashes, the restart starts with an empty table and no retired list: every request picks a new generation (a new Finch pool), and the pools created before the crash are in neither the table nor the list, so the sweep never stops them. Requests that call `generation/1` during the restart raise `ArgumentError` (no table) instead of fetching. The sweep is the likely crash: `Finch.stop_pool/2` does `Supervisor.stop(pid)` and `get_pool_supervisor` does `Supervisor.count_children(pid)` on a pid found in a registry, and both exit the caller if that pool supervisor died in between (for example when its Finch instance restarted).

**Suggested fix.** Own the table from a supervisor (as `Cache.Resources.Supervisor` does) or the app, keep retired pools in it too, and wrap the per-pool stop in a `catch :exit` so one vanished pool doesn't crash the sweep.

---

## 6. The server stays "ready" while its ImagePipe instance isn't running

- **Severity:** low
- **Confidence:** by reading
- **Where:** `image_pipe_server/lib/image_pipe_server/health.ex:30,49-54` (readiness follows two flags only), `image_pipe_server/lib/image_pipe_server/application.ex:121-135` (`:one_for_one`)

**Evidence.** `serving?` is set once after the listener starts and never cleared. If the instance stops and is restarted by `ImagePipeServer.Supervisor` (finding 1's cascade, a cache root takeover loop, or a hung cache root blocking `Root.init`'s owner claim, which is synchronous file I/O), `/health/ready` keeps answering `200` while image requests get 500s ("not running") or 503s. A load balancer keeps sending traffic to that replica.

**Suggested fix.** Have readiness also check that the instance's configuration is published (one `persistent_term` read) and, optionally, that the pool is registered.

---

## 7. A hung credential fetch blocks its S3 cache entry for good

- **Severity:** low (the bundled providers have per-request timeouts; a custom `:provider` or a trickling endpoint doesn't)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/source/s3/refresh_cache/entry.ex:153-156` (`Task.async` with no deadline), `:250` (single-flight: no new fetch while one runs), `:56-63` (callers give up after 10 s)

**Evidence.** The entry runs one fetch at a time and never times it out. If `fetch_fun` doesn't return, every `get/2` for that bucket waits 10 s and fails with `{:error, :timeout}` (the waiter stays in `waiters`), no refresh can start, and `:check_idle` never retires the entry because `task` isn't nil. Only a restart recovers. Req's `receive_timeout` is per chunk, so even the bundled metadata calls aren't strictly bounded.

**Suggested fix.** Start the fetch with a timer (for example 2× the call timeout) and `Task.shutdown(task, :brutal_kill)` it on expiry, replying `{:error, :timeout}` and letting the next `get/2` start a new one.

---

## 8. A restarted Admission leaves the old startup scan running

- **Severity:** low (duplicate disk work on large caches)
- **Confidence:** by reading
- **Where:** `lib/image_pipe/cache/file_system/admission.ex:132-136` (`spawn_monitor`, unlinked), `:158-174`

**Evidence.** The scan is unlinked so it can crash without taking Admission down. The reverse isn't handled: when Admission dies or its Root shuts down, the scan keeps listing the whole tree (5.5 s per 20 000 entries per `perf-review-2`) and only dies at its first `GenServer.call` to the dead pid. A restarted Admission starts its own scan at the same time, so a restart doubles the I/O while the cache is already degraded.

**Suggested fix.** Have the scan monitor Admission and stop when it goes (check between partition groups), or link the two with Admission trapping exits and handling the scan's `{:EXIT, …}` in place of the monitor.

---

## Checked and found sound

- **Processing pool:** queued callers get `{:processing, :unavailable}` when the pool dies (calls are caught); active workers are linked and die with it; `terminate/2` ends queued and active workers with `{:shutdown, {:processing, :unavailable}}`, which `run/3` maps cleanly. No path sends a `:release` for an unknown token while workers don't trap exits (checked every worker: `run/3` tasks, overlap tasks, the delivery producer).
- **Source lock (`Cache.Work`) and output flights (`OutputWork`) restarts:** waiters monitor the server and fall back to `:busy`/`:bypass`; old leases fail `current?/1`, so `publish/3` under `:global.trans` can't interleave with a new coordinator's lease. Every `Map.fetch!`/pattern match in their handlers holds under the members ⊆ flights and refs ⊆ locks invariants.
- **ETS owners:** `Cache.Resources` keeps its table in a supervisor and re-monitors owners on restart; `Memo`, `SourceRecords` and `DnsCache` readers tolerate a missing table (`RecentTable` rescues, `DnsCache` falls back to a direct lookup). `RefusedRoots` and `CheckedDirs` lose their tables only if their idle GenServers crash, which nothing triggers.
- **Delivery coordinator:** every graceful stop path halts the producer first, owner death is seen through the monitor, and pooled prepares are bounded by the pool's own queue and processing deadlines.
- **Overlap download:** the pool's owner is the `Download` process, so closing it cancels a queued turn and its `terminate/2` stops the worker and readers.
- **Server shutdown order:** children stop in reverse, so the image listener drains before the instance and pool stop and the health listener answers until the end; inside each cache, Writers stop before Admission.
- **Late replies:** `GenServer.call` timeouts in the request path drop late replies (aliases); Finch messages left by a cancelled relay are discarded by Bandit's HTTP/1 handler between requests.

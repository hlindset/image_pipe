# Owned-partition retirement protocol

Status: local protocol spike for `image_plug-015.9`, 2026-09-25. Implements the
publication/retirement portion of the [shared-cache spec](shared-filesystem-cache-partitions.md).
The [executable probe](../../scripts/partition_probe/README.md) passes locally;
no shared mount is qualified. Input selection semantics remain tracked by `015.4`.

## Namespace rules

Create `partitions/<incarnation>` exclusively once during writer initialization.
Incarnation and generation IDs are never reused, including after reboot. Only
that initialization may create the incarnation root. All later directory creation
is one component at a time beneath an existing root; never use recursive mkdir
that can recreate missing ancestors. On missing ancestors, stop publishing for
that incarnation, drop its writable state, and allocate a new incarnation.
If initial root creation has an uncertain result, abandon that identity rather
than issuing another root-creation operation with it.

Keep `trash/` outside `partitions/`. Discovery and warmup consult only partitions;
trash is never a lookup fallback. Every operation carries its original incarnation
and generation ID, never a mutable alias for the current writer. Outstanding work
must not be redirected to a replacement incarnation.

## Publish and retire

Prepare a unique staging directory, write and close its body and metadata, then
atomically rename it to the exact generation destination. Published bytes and
generation names are immutable. The publisher serializes its own staging steps;
no background cleaner deletes active staging. Operation retries inspect the exact
destination and validate completeness/identity before treating a lost reply as
success. An absent destination can be retried with new staging or abandoned.

A sweeper may nominate an inactive incarnation using heartbeat age and a generous
grace period. Missing heartbeat during startup requires an observation/grace period,
not immediate deletion. The heartbeat is a retention hint only. A false nomination
is allowed to cost cache hits; no recheck can prove the writer has stopped.

Retire with one rename:

```text
partitions/<incarnation> -> trash/<incarnation>
```

Only after retirement may a cleaner recursively unlink that tree. A retry uses
the same destination name. If the active name is absent, inspect/reap the matching
trash name; never restore it. An ambiguous rename result is reconciled by those
exact names. Other errors are deferred and reported, not counted as reclamation.
Competing sweepers may find an already-missing tree. Partial cleanup is retried
in bounded batches; sharing violations, busy files and nonempty directories stay
in the pending inventory. Rate-limit repeated failures.

Owner eviction similarly renames an exact immutable generation into a uniquely
named trash entry before unlinking. It cannot target a replacement generation.
Do not clean abandoned staging in a still-writable incarnation on age alone.
Reclaim it after its operation has conclusively finished, or retire the entire
incarnation. A stuck operation occupies its bounded resource slot until resolved.

## Why a resumed writer is safe

If publication completes before retirement, its generation moves with the tree.
If retirement wins before path resolution, publication fails on missing ancestors.
If the kernel already resolved directory handles, a delayed operation may finish
inside the retired tree. It cannot create a new discoverable incarnation because
the application never recreates that root. Reaping may need another pass.

An already-open heartbeat can likewise update only the retired inode. A writer
need not observe a marker for safety. No ownership lock or permanent tombstone
is required under these namespace rules. Remaining readers with stale directory
cache results may still access the old tree; they must validate/acquire bytes as
below, so stale visibility yields a valid old entry or a miss, not a partial hit.

This argument assumes operations on resolved directories remain attached to those
directories when renamed and cannot resurrect removed ancestors. Qualify that
behavior on the actual mount/client; application interleavings cannot establish it.

## Readers and adoption

Read bounded metadata, then acquire the body from that exact generation. Missing,
partial, mismatched, or corrupt data is a miss. Preserve a stable resource through
response delivery/lazy decoding; mere existence or stat checks do not acquire it.
The conservative initial implementation may copy into a node-local request file
before handing out a path. Open/unlink semantics need qualification when using
held shared-file descriptors instead. Cache failure before acquisition may bypass;
failure after committing HTTP headers cannot be repaired by promising fail-open.

For admitted adoption, read source evidence and hard-link its immutable body into
the destination's unique staging directory, or copy through a held reader. Preserve
source context and all freshness deadlines in new generation metadata. Verify the
body corresponds to the evidence before publishing. The original writer's liveness
is irrelevant. Deletion before link/open yields a retry or miss; deletion after a
successful link leaves the adopter's reference intact. Target retirement follows
the same argument as ordinary publication. Ambiguous link results require checking
the staged destination rather than treating a returned error as proof of absence.

Multiple adopters can hold links independently. Every adopter pays its full logical
retention charge; unlink does not imply physical block reclamation. A temporary
reader copy/link is not durable admission and has a separate resource budget.
No inventory import or peer hit without local admission creates retained ownership.

`Generation.adopt` provides the leased storage operation: validate bounded metadata
in the application VM, link and verify the staged body, then publish the immutable
pair. It preserves serialized freshness evidence. Unsupported hard links fall back
to bounded copying; an uncertain link result is reconciled against the destination.
Local tests cover link survival, corruption, missing bodies, evidence preservation,
and receiving-partition retirement. Cross-filesystem fallback and shared-mount
failure injection still require qualification. Runtime admission scheduling remains
separate from this storage primitive.

## Progress, resource bounds, and qualification

The protocol guarantees safe outcomes under its filesystem assumptions, not a bound
on kernel I/O completion. `015.2` must limit workers, outstanding operations, queue
length, and reserved staging/reader bytes. Timed-out operations keep their slots
until actually terminated or completed; do not spawn unlimited replacements.
The local coordinator remains responsive and bypasses cache when saturated.
Late immutable completion is tolerated; freshness evidence is never rebased to
completion time. Progress/reclamation requires the mount eventually respond and
retired writers eventually stop issuing operations. Permanent failure is observable
degraded caching, not a strict-cap guarantee.

Before claiming mount support, `015.8` must run independent clients against the
same disposable root: race rename/link/open/unlink, observe stale directory caches,
stop/resume writers around retirement, reconnect clients, interrupt the server or
network, and test ambiguous outcomes. Verify incomplete crash-recovered generations
are rejected, permissions/link support, and reader lifetimes. Repeat with copy
fallback and failed deletion. Document the exact client/server/mount configuration.

Local scheduling tests cover the protocol's critical boundaries and a deliberate
unsafe-recreation counterexample. They are not exhaustive distributed-system proof.
The local protocol is concrete enough for bounded-I/O and generation implementation;
production request integration and real-mount evidence remain separate gates.

## Executor implementation progress

`SharedFileSystem.IO` runs bounded operations in a local OTP helper VM over
standard I/O. It does not enable distributed Erlang. Call deadlines include time
waiting in the coordinator mailbox; expired requests never start. Timed-out and
orphaned operations retain their operation/working-set reservations until completion.
Adapter startup obtains a shared local client handle. Before enqueueing, callers
claim a fixed admission slot and check the encoded request-size ceiling. Defaults
allow 16 pending requests of at most 1 MiB each, separately from active-operation
budgets. Timed-out calls keep their admission slots until consumed; the coordinator
monitors abandoned claims so death between claiming and sending cannot leak a slot.
Helper or call-proxy failure degrades the executor without automatic replacement,
since lost control does not prove underlying OS work has finished. The executor
child is temporary for the same reason. Subsequent adapter integration must expose
this degraded state and keep normal uncached image delivery available.

The executor also owns count- and byte-bounded persistent resource reservations.
A reservation is acknowledged before use; an unacknowledged offer expires and is
cleaned up. Every operation touching a reserved staging/reader directory carries
its lease. Closing a lease rejects new operations, waits for already-issued ones,
then executes cleanup in the helper. Caller death follows the same path. Failed
cleanup remains charged and can be retried by maintenance. A successful operation
alone does not release its persistent file budget. Cleanup consumes an ordinary
operation slot, so resource cleanup cannot spawn an unbounded worker population.

`SharedFileSystem.Partition` provides exclusive incarnation creation, nonrecursive
staging ancestry, heartbeat, retirement and fresh-identity recovery. Pure generation
planning allocates the exact cleanup path before resource reservation or I/O.
`SharedFileSystem.Generation` reserves staging/reader bytes, applies one request
deadline, and performs bounded body copies through the executor. Publication closes
both files before renaming their directory; uncertain rename results are reconciled
against the exact generation and body digest. Reads bound and validate the envelope,
reject compressed terms, and verify size/digest before returning a local reader path.
Original storage keys include both input identity and byte identity.

Source generations can contain validation evidence or a nil-record marker without
an original body. Record-only publication uses the same staging, rename and exact
destination reconciliation, reserving metadata bytes only. The I/O helper validates
the storage envelope and carries application metadata as a bounded encoded binary.
The application VM safely decodes that payload with known schema atoms and validates
source records; cold helper VMs therefore need no knowledge of host identity atoms.
Neither layer accepts compressed terms or trailing serialized bytes. Reading or
publishing evidence preserves its received time and origin headers.

`SharedFileSystem.Sources` coordinates local selection and same-key acquisition.
It reuses pre-enqueue count/payload admission, bounds owners and waiting callers,
and checks absolute deadlines before selection mutations. Ownership offers require
acknowledgement; waiting callers and unacknowledged offers expire. Caller death or
release hands ownership to a live, unexpired waiter. Publication and discovery
check both the caller and key under the coordinator's active lease.

Its supervisor retains only a routing handle and clock high-water checkpoint.
Coordinator restart revokes old leases and turns lost selection state into a
global validation cutoff, preserving rejection knowledge without copying a full
selection table on every read. Requests resolve the replacement coordinator through
the same client handle. Local tests cover bounded admission, coalescing, caller
death, restart during clock rollback, independent scopes, and a disk publication
that completes after coordinator restart but cannot replace the newer selection.

Completed reader directories are registered with the existing node-local resource
tracker before acquisition returns. Explicit release or caller death can therefore
remove them after helper or executor failure; tracker worker restarts preserve its
ownership records. Shared operations whose completion is unknown retain their
reservations and are never handed to this tracker for early deletion. Losing the
call channel disables executor admission even if the helper remains alive.

These remain internal building blocks. Source/output payload validation, lookup integration,
and public adapter integration are separate steps. Recovery of uncertain operations
still needs work. Helper startup in packaged releases and cross-process transfer
costs also need deployment/performance validation.

`SharedFileSystem.Discovery` can enumerate current partitions and exact-key
generation paths. It validates identifier-shaped directory names, limits inspected
names/candidates, and distinguishes complete results from a budget-limited search.
Callers can refresh a cached partition list and retry after a miss. Generation
publication and discovery share path construction, including original-key scoping.

`SharedFileSystem.Index` bounds keys, encoded hint bytes, and candidates per key.
Only confirmed reuse/publication establishes requested-entry recency; querying a
hint does not. Inventory imports occupy a separately bounded fraction of keys and
bytes, cannot displace requested entries, and are evicted before them.

`SharedFileSystem.Locations` owns the hint index and a count-bounded partition
snapshot with a monotonic TTL. Same-key searches coalesce locally; active jobs,
waiters, and pre-enqueue request payloads have independent limits. An empty
cached-list search refreshes partitions within one search deadline. Readers can
force refresh when named candidates prove unusable. Each search performs at most
two bounded candidate scans, and truncated partition snapshots preserve their
limited status. Discovery alone does not confirm a hint or record demand.
Individual caller expiry/death releases its waiter without cancelling work used
by others. The isolated executor retains reservations for uncertain filesystem
operations even after the search deadline. The coordinator remains responsive
while searches run in supervised tasks.

`SharedFileSystem.Lookup` tries indexed locations before coalesced discovery and
refreshes once more when named candidates are unusable. One request deadline and
attempt budget cover all phases; each exact location is attempted at most once.
Missing/corrupt generations are forgotten, while executor saturation, timeout,
unavailability, and lost source ownership abort the lookup. A complete exhausted
search is a miss; truncated search or attempt exhaustion is a distinct limit
result. Output metadata is validated as response metadata, originals require
valid source evidence and an exact expected byte identity, and bodies are copied
and digest-checked before returning a reader. Source discovery installs evidence
through `Sources` under the caller's existing lease. Only successful reads update
the hint index.

`ImagePipe.Cache.SharedFileSystem` now implements both public cache contracts.
Its named runtime supervises the isolated executor, source coordinator, location
index, and heartbeat/partition recovery. Request callers resolve current worker
handles from supervisor-owned ETS. Location-worker replacement renews its handle;
partition rotation preserves source coordination. The executor and source-scope
supervisor are not automatically replaced after losing their ownership state.
Their internal workers retain the recovery rules described above.

Start the runtime with `name`, shared `root`, and node-local `local_root`, then use
`{ImagePipe.Cache.SharedFileSystem, runtime: name}` for output and optionally input
caching. Output-only mode uses this runtime as its explicit source-state owner.
Validation occurs before startup I/O. Output writes use leased local staging and
bounded append operations before immutable publication; acquired outputs are
returned as bounded binaries. Sink callbacks share a decreasing I/O allowance;
time spent producing chunks between callbacks does not consume that allowance.
Original hits return stable reader handles. Local
source selection is installed under its lease before best-effort disk publication;
failure to store an original does not prevent recording new validation evidence.
Wire tests cover two independent runtimes, cross-node output/original reuse,
conditional requests, independent fresh pixels, missing originals, helper failure,
location-worker replacement, and partition rotation. These use local disk and do
not qualify a shared mount. Retention, adoption, warmup scheduling, expanded
operational controls, and shared-mount qualification remain in progress.

`SharedFileSystem.Retention` supplies a pure W-TinyLFU policy using the existing
frequency sketch and cost-per-byte scoring. Real requests increment the sketch
and promote retained entries; offers and inventory ranking do not invent demand.
The window and segmented main queues have byte and entry bounds. Admission walks
a bounded victim prefix, returns exact generation descriptors, and leaves the
prior state intact on rejection. Delayed forgetting cannot remove a replacement.
Protected entries and scored known keys provide bounded inventory candidates.

`SharedFileSystem.Retainer` runs one supervised adoption transaction at a time.
It accepts bounded requests before enqueueing, coalesces duplicate candidates,
and keeps popularity updates responsive during mount I/O. It checks admission
before adoption and again before committing the policy transition, so intervening
requests cannot be overwritten by a stale policy snapshot. Logical charges include
the full serialized metadata envelope and body, even for hard links. Exact local
victims are renamed into trash before bounded member removal. Failed removal keeps
its charge and supports an explicit retry; uncertain adoption retains its pending
charge and stops further writes through that owner. Scheduling returns before
background adoption completes. The worker is not yet connected to the runtime.

Runtime integration still needs to route ordinary publication through admission,
connect successful lookups to adoption, and preserve accounting across owner
restart and partition rotation.

`SharedFileSystem.Inventory` publishes an atomically replaced, count/byte-bounded
prefix of locations ranked by the retention owner. It uses leased staging and the
same isolated I/O executor. Ambiguous replacement is acknowledged only when the
destination matches the exact publication. Readers reject compressed/trailing,
oversized, incompatible, stale, and malformed payloads, and reconstruct paths from
validated namespace/key/generation identifiers under the advertised incarnation.
Import provides disposable hints; generation validation remains mandatory.
Periodic ranking/publication, asynchronous warmup scheduling, and request lookup
orchestration still need integration with the retention owner and public adapter.

Directory enumeration uses an optional POSIX executable that streams `readdir`
entries and stops after the configured name budget plus one lookahead. It retains
no directory-wide name list; unusable names consume the same budget. The Elixir
reader bounds the executable's output and waits for its exit inside the isolated
I/O operation, so stalled enumeration keeps its operation reservation.

Build this helper on the deployment target before assembling a shared-cache release:

```sh
mix image_pipe.shared_cache.build
```

The build uses `CC` (default `cc`) and only the platform C library. Its source is
included in the Hex package; the generated executable is platform-specific and
is built into the application's `priv/shared_cache` directory for release inclusion.
The compiler is not needed at runtime, and local-cache-only deployments do not
need this build step. A missing executable returns a cache error. POSIX helper
portability and actual shared-mount behavior still require qualification.

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

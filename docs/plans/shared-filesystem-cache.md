# Shared filesystem cache design

Status: superseded by [Shared filesystem cache with owned partitions](shared-filesystem-cache-partitions.md).
This document records the earlier coordinated-source design.

The input/source-state foundation is implemented. The
[EFS ownership spike](efs-ownership-spike.md) records partial evidence, an
unqualified locked-anchor candidate, and the outstanding recovery/cancellation
decisions that gate shared-adapter implementation.

## Scope and guarantees

Keep `ImagePipe.Cache.FileSystem` as a cache whose root is exclusively owned by
one node, with local W-TinyLFU admission and eviction. Add
`ImagePipe.Cache.SharedFileSystem` for multiple machines sharing a cache root.
Each root uses one adapter's storage model; correct root assignment is host
configuration responsibility.

The shared adapter targets a **soft limit on retained cache data**, backed by an
operator-configured storage ceiling where the volume supports one. A sweeper
reclaims space toward a low watermark. Temporary files, reader pins, metadata,
and delayed deletion consume additional space and must be included in operational
capacity planning. The adapter does not provision storage quotas.

Cache-write failures, including a full volume, fail open: successfully generated
images are still delivered, while the cache failure is observable. Source and
processing errors retain their normal behavior. Approximate popularity and
occasional excess eviction are acceptable; mismatched bytes, stale-record
resurrection, and invalid freshness extensions are not.

## Separate storage ownership from eviction policy

The shared adapter uses concurrent publication and periodic eviction rather than
one globally synchronized W-TinyLFU inventory. Local admission queues and byte
counters cannot represent files changed by other nodes.

Nodes maintain local frequency sketches and publish replaceable per-node
snapshots. Each sweep aggregates compatible snapshots once, using frequency and
generation cost to favor valuable entries. Missing or stale snapshots affect
hit rate, not correctness. Snapshot compatibility, expiration, and aging must be
defined; repeatedly adding the same snapshot to a running total is incorrect.

Reuse sketch and scoring logic where useful. The local adapter retains its
window and segmented LRU queues. Shared eviction inventories actual files and
does not depend on synchronizing those queues across machines.

## Immutable generations

Each generation has its own metadata and body, prepared in a unique staging
directory and published as a complete unit using the supported filesystem's
rename semantics. Generation identifiers are never reused. A schematic layout:

```text
outputs/<key>/<generation>/{meta,body}
sources/<key>/<revision>/meta
originals/<input-key>/<byte-identity>/<generation>/{meta,body}
staging/<unique-id>/...
state/<node-id>/...
locks/...
```

The exact layout is an implementation decision. Original bodies may be shared
by successive source revisions, allowing a `304` to update validation evidence
without copying the body.

Path components are encoded/digested identities. Byte identity is an opaque
source-owned seed, so originals remain scoped to the input key, including its
fetch context and storage partitions. Cross-key deduplication would require an
independently computed content digest and an exact record-to-body binding.

Output lookup selects a complete, verified generation for the exact output key
in deterministic order. The key already incorporates source byte identity;
creation time is not a freshness ranking. If a generation disappears or fails
verification, try another or return a miss. Equivalence assumes the same
representation and encoder configuration across participating nodes.

Eviction targets the exact generation inspected, never a key-wide mutable
metadata filename. Already-removed generations count as successful cleanup.
Readers must hold bytes safely for their lifetime. Body sharing, reader pins,
and staging cleanup need explicit lifetime rules; age alone does not prove an
in-progress file is abandoned.

## One owner for source state; optional original bytes

`ImagePipe.Cache.Input.Adapter` provides the input/source-state behaviour,
implemented by the local filesystem adapter and intended for the shared adapter.
The output-cache behaviour is separate. Its responsibilities are:

| Operation | Contract |
| --- | --- |
| Lookup | Return the current source record with an opaque revision, an invalidation marker, or a miss. |
| Open original | Return a stable local path containing the selected source bytes, plus a releasable lifetime handle. |
| Acquire update ownership | Obtain exclusive authority to validate and publish for an input key. |
| Publish | Commit a source record and optional original bytes under valid ownership. |
| Invalidate | Invalidate an expected revision without removing a newer replacement. |
| Release | Release update ownership or the caller's hold on original bytes. |

Callbacks and types are defined in `Cache.Input.Adapter` and `Cache.Input.Snapshot`.
Execution owns origin requests,
freshness policy, limits, and response handling. Adapters own persistence,
synchronization, and byte lifetimes. Validate host-implemented adapter results at
this boundary.

Output-only caching retains source records without storing originals. When an
input cache exists, it owns source state. The current fallback for custom output
adapters uses node-local coordination; the shared adapter must explicitly resolve
its own shared record-only owner rather than using that fallback.

## Source revision protocol

Source validation and publication are serialized per input key:

1. Acquire update ownership and reread the current record.
2. Reuse a sufficiently fresh record, or fetch/revalidate through the source adapter.
3. Publish the next revision with changed bytes, retained byte identity for a
   `304`, or an invalidation marker.
4. Release ownership, including on errors and caller termination.

Readers select the highest committed revision and apply its freshness rules.
Wall-clock timestamps and origin ETags are not revision ordering mechanisms.
An evicted body causes a fetch; it must not make an older source revision current.
A corrupt latest record requires revalidation rather than fallback to an older
record. Invalidation markers likewise suppress older records.

Freshness timestamps cross machine boundaries even though revision ordering does
not use clocks. Define a supported maximum relative clock skew and conservatively
shorten freshness and stale-serving deadlines by that allowance. If the clock
contract cannot be met, revalidate instead of trusting shared freshness evidence.
The skew allowance and detection/configuration policy remain to be specified.

Retain a small latest-revision record or equivalent high-water mark while old
revisions remain discoverable. Reclaiming this state requires a protocol that
prevents revision reuse and resurrection, including delayed readers and writers.
A late decode failure invalidates only its expected revision.

On coordination failure, requests may fetch and process uncached, but must not
publish without valid ownership. Filesystem lock loss and stale-owner publication
are correctness concerns here, unlike duplicate sweeps. A lock acquired once is
not sufficient evidence of ownership after an arbitrary partition.

Lock acquisition and request-facing cache I/O need bounded waiting and an uncached
bypass path. A timeout does not cancel a filesystem operation: abandoned work
must be prevented from publishing later. Establish isolation/cancellation and
resource bounds for stalled mount operations on the supported client; moving I/O
to a BEAM task alone does not establish those guarantees.

## Sweeper coordination and recovery

Each node may periodically try an exclusive filesystem lock on a permanent lock
file. The winner performs one sweep; others skip the round. No distributed Erlang
cluster or long-lived application leader is required. Do not delete or replace
the lock file, or steal ownership based on an old timestamp.

Design generation deletion to tolerate overlapping sweepers: overlap may reduce
hit rate through excess eviction but must not corrupt entries or revive stale
source state. The sweeper discovers published generations, superseded data,
abandoned staging work, and failed deletions. Failed removal must not be counted
as reclaimed space. Work per pass should be bounded and yield under load.

Crash recovery must handle incomplete staging, uncertain publication outcomes,
orphan bodies, reader termination, and interrupted sweeps. Publication/retry and
cleanup must be idempotent. Source-record cleanup follows the stronger revision
rules above.

## Filesystem support and implementation sequence

Support specific, tested filesystem/client configurations. Establish guarantees
for cross-client locks, lock loss/recovery, atomic publication, directory
visibility, and pinned-reader lifetime. These guarantees are prerequisites for
the source revision protocol, not assumptions supplied by the adapter name.
The initial target is Linux clients using NFSv4.1 against Amazon EFS. EFS provides
advisory locks; ordinary writes do not check ownership. Prototype lock loss and
stale-owner prevention before committing to the mutation protocol. Hard-mounted
NFS I/O may retry indefinitely, so request deadlines require an isolated I/O
mechanism with bounded outstanding work. EFS does not supply the optional hard
capacity ceiling; its cache limit remains an application-managed soft target.
See [EFS locking](https://docs.aws.amazon.com/efs/latest/ug/features.html),
[mount settings](https://docs.aws.amazon.com/efs/latest/ug/mounting-fs-nfs-mount-settings.html),
and [unsupported quota attributes](https://docs.aws.amazon.com/efs/latest/ug/limits.html).

SMB is a possible later profile sharing generation layout and eviction policy.
It needs separate validation of lock recovery, publication visibility, and reader
lifetime for a named client/server configuration. Sharing modes can prevent
deletion of open files; defer failed cleanup and retain its space in accounting.
Linux SMB lock behavior also varies with kernel and mount options; keep locks on
dedicated permanent files. See [SMB sharing modes](https://learn.microsoft.com/en-us/rest/api/storageservices/managing-file-locks)
and [Linux filesystem locking](https://man7.org/linux/man-pages/man2/flock.2.html).

Include safe reclamation of source lock objects and per-node state in
the lifetime design; deleting a referenced lock file can break exclusion.

1. Define the input/source-state contract and migrate the local adapter, preserving
   output-only caching, freshness, invalidation, and resource cleanup.
2. Implement shared generations, source revisions, byte lifetime handling, and
   failure recovery against the chosen filesystem contract.
3. Add approximate eviction, popularity snapshots, configuration documentation,
   and telemetry, including Logger and trace-capture coverage.

Share low-level path, metadata, verification, and read mechanics where their
contracts match. Keep publication, coordination, inventory, and eviction owned
by each adapter rather than generalizing the existing mixed-responsibility Store.

Use deterministic interleavings between independent adapter instances in one BEAM
as the primary protocol test strategy. Cover publication/replacement/eviction,
`304` refresh, revision-aware invalidation, missing originals, uncertain commits,
crashes, full storage, active readers, and injected clock skew. Include distinct
sources sharing a byte-identity seed but returning different pixels. Request-level
tests verify freshness, pixels, and fail-open delivery, including blocked owners
and no late publication after a request abandons cache work.

A small cross-machine suite on the supported filesystem validates assumptions
the local model cannot establish: cross-client locks, visibility, lock recovery,
and unresponsive mounts. It need not duplicate every protocol interleaving.
Measure lookup directory costs, sweep I/O, and hit-rate impact before choosing
snapshot intervals, watermarks, and generation-retention limits.

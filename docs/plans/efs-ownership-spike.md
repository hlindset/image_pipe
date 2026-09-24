# EFS ownership and recovery spike

Status: partial investigation for `image_plug-015.1`, 2026-09-24. **No EFS
configuration is qualified.** The available machine is macOS/Darwin 27.0.0;
there are no supplied EFS clients. Local evidence is four passing subprocess
tests in `scripts/efs_probe/test_probe.py`. The reusable
[probe and two-client runbook](../../scripts/efs_probe/README.md) cover the next
experiments. Task `015.2` remains blocked on the ownership decision and evidence.

## What the protocol permits

EFS provides advisory locks and close-to-open consistency. An ordinary write
does not enforce a conflicting advisory lock. This makes a separate lock file
useful for coalescing requests or avoiding duplicate sweeps, but not sufficient
to protect a mutable source head from a delayed former owner.
[AWS EFS semantics](https://docs.aws.amazon.com/efs/latest/ug/features.html)

In NFSv4.1, RENAME carries directory handles and names, with no lock stateid.
WRITE carries a stateid, and revoked state can be rejected. Atomic rename
protects completeness of publication; it does not establish current ownership.
A process can check a lock, lose it, and later rename over another owner's head.
[RFC 8881, RENAME](https://www.rfc-editor.org/rfc/rfc8881.html#section-18.26),
[WRITE](https://www.rfc-editor.org/rfc/rfc8881.html#section-18.32),
[stateid validation](https://www.rfc-editor.org/rfc/rfc8881.html#section-8.2.4)

Linux documents EIO for I/O using lost NFSv4 locks and defaults
`nfs.recover_lost_locks` to disabled. In the inspected Linux v6.12 source,
read/write stateid selection rejects `NFS_LOCK_LOST`; expired lock recovery
marks that bit when automatic recovery is disabled. This is evidence for a
candidate to test, not qualification of a distribution kernel or every I/O path.
[Linux lock documentation](https://man7.org/linux/man-pages/man2/fcntl_locking.2.html),
[stateid selection](https://github.com/torvalds/linux/blob/v6.12/fs/nfs/nfs4state.c),
[expired-lock handling](https://github.com/torvalds/linux/blob/v6.12/fs/nfs/nfs4proc.c)

## Candidate: authoritative state in the locked inode

Keep immutable generations for image bodies and source revision payloads.
Explore a permanent authoritative source-state anchor containing the current
revision identity or invalidation marker. Its content is mutable; its inode is
never replaced while clients can reference it.

1. An isolated worker opens the anchor and acquires a POSIX record lock using
   `fcntl` (`lockf` in the probe). The lock and all anchor I/O use the same
   process and descriptor. Do not mix `flock`, rename or another descriptor into
   this ownership protocol. Closing another descriptor for the same inode can
   release process-associated POSIX locks, so the worker must own the descriptor
   lifecycle exclusively.
2. Reread authoritative state after acquiring the lock. Resolve origin freshness
   through the existing source layer, then prepare a complete immutable revision
   and optional original. A generation's existence alone never makes it current.
3. Commit through synchronous writes to the locked anchor, followed by the
   required durability operation. The probe uses `O_SYNC`, `pwrite` and `fsync`.
   The production record format and crash protocol remain open: no atomicity of
   a 4 KiB write is assumed. Invalid or incomplete state forces revalidation;
   never select an older generation as a fallback authority.
4. On ownership/I/O loss, abandon that validation attempt. Never close/reopen,
   reacquire and replay the old mutation as if ownership were continuous.
   A new attempt acquires ownership and rereads/revalidates from scratch.
5. Readers must establish the qualified cache-coherency boundary before trusting
   the anchor. An unlocked cached read or directory listing is not sufficient
   evidence of the newest committed source revision. Initially test locked reads;
   optimize only after proving equivalent semantics and measuring latency.

The proof obligation is that every authoritative write is tied to the exact
valid lock state, including queued/retried writes and recovery. Test with A
partitioned, B acquiring ownership and committing, then A resuming both newly
issued and already-pending writes. B's record must remain authoritative.
Examine the deployed kernel and capture enough client evidence to establish why.

Anchor allocation and reclamation also remain open. Deleting and recreating a
lock object can split exclusion across inodes. Permanent per-key anchors alone
are not a bounded metadata design. Select a safe bounded allocation scheme or
prove quiescent reclamation before claiming the volume meets its space contract.

## Deadlines and uncertain commits

A controller timeout cannot retract a rename or write already sent to storage.
The local lost-reply test deliberately publishes a complete generation and
crashes before acknowledging it; the next reader finds that generation.

Distinguish an **invalid former owner**, which must never overwrite a successor,
from an **unacknowledged operation still holding valid authority**. The latter
may commit after the caller stops waiting. The original design's absolute
"no late publication after abandonment" requirement is not established by
process isolation or a timeout. Before `015.2`, decide whether to accept an
unknown commit outcome resolved by operation identity and fenced ordering, or
require a stronger cancellation protocol. This spike does not silently relax
that requirement.

## Evidence and remaining gate

| Experiment | Local result | EFS result |
| --- | --- | --- |
| Independent-process lock contention, handoff and process death | Passed | Not run |
| Complete directory publication observed by another process | Passed | Not run across clients |
| Unlocked rename bypasses another process's anchor lock | Reproduced | Not run; RFC supplies no lock-state binding |
| Corrupt anchor requires a miss/revalidation | Probe rejects corrupt record | Not run |
| Commit succeeds but acknowledgement is lost | Reproduced | Pending-I/O/RPC recovery not run |
| Controller deadline with stopped worker | Returned timeout | Stalled NFS/helper resource behavior not run |
| Expired owner's same-descriptor write fails; successor survives | Cannot simulate with local unlock | Not run |

Next: provision or supply the disposable two-client EFS environment in the
runbook, record exact versions/options, and run fault experiments. If the anchor
candidate fails, revisit immutable conditional-link successor protocols (with
their own visibility, recovery and garbage-collection proof), externally fenced
coordination, or per-node source state. Distributed Erlang alone does not make a
filesystem rename reject an old owner. No shared adapter implementation should
depend on the unproven candidate yet.

## Bunny Magic Containers is a different deployment model

Bunny documents node-bound, per-pod volumes. Containers in one pod may share a
volume, but different pods cannot; new replicas receive independent volumes.
The page does not specify the underlying filesystem or mount protocol.
[Bunny persistent volumes](https://bunny.net/docs/magic-containers/persistent-volumes)

For one ImagePipe BEAM instance owning each pod's cache root, the existing local
`FileSystem` adapter fits that ownership model. These volumes do not provide a
cross-replica shared cache and cannot substitute for the EFS qualification setup.

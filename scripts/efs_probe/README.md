# EFS ownership probe

Beads: `image_plug-015.1`. This is a stdlib Python syscall probe, not a cache
adapter. No AWS resources or network fault rules are created by it. It writes
only within a disposable probe directory created by `init`. Run workers as the
same unprivileged UID; keep the directory away from application data.

## Local check

```sh
mise exec -- python3 -m unittest discover -s scripts/efs_probe -v
```

The tests use separate OS processes to exercise record locks and crash cleanup.
Passing on a local filesystem does **not** qualify EFS. `smoke` always reports
`efs_qualified: false` because it does not inject partitions.

## Disposable EFS setup

Use two separate Linux EC2 instances in one VPC and an EFS Regional filesystem
with a mount target reachable by both. Two containers on one kernel do not
exercise independent NFS clients. Use a concrete supported distribution image,
record its AMI ID and kernel package version, and use the same versions on both.
The profile remains **unqualified** until the experiments below pass.

1. Create a dedicated test security group allowing NFS TCP 2049 from the two
   client instances. Keep SSH/control access separate from NFS traffic.
2. Mount the same EFS filesystem at `/mnt/efs` on both with NFSv4.1, hard mounts
   and server-side locking. Start with AWS's recommended mount settings; record
   actual options, kernel, EFS ID, region, mount targets, helper/proxy versions and
   TLS use. Reject `local_lock` modes and `nfs.recover_lost_locks=1` for this
   candidate. Do not change a production mount to run the experiments.
3. Install Python 3 and `findmnt`. Copy `probe.py` to `/tmp/efs-probe.py` on both.
4. On client A, create a unique directory:

   ```sh
   python3 /tmp/efs-probe.py init /mnt/efs
   ```

   Use the returned path on both clients. `PROBE`, `anchor`, `staging` and
   `generations` must already be visible on B. Workers never replace `anchor`.
5. From a controller with SSH aliases `efs-a` and `efs-b`:

   ```sh
   python3 scripts/efs_probe/probe.py smoke /mnt/efs/imagepipe-efs-probe-RETURNED-ID \
     --a efs-a --b efs-b --script /tmp/efs-probe.py > efs-smoke.jsonl
   ```

The smoke checks contention, lock handoff, synchronous anchor writes,
cross-client visibility of a complete directory generation, and lock release
after process death. Its unsafe control deliberately overwrites a head by rename
without holding the lock, while the other worker holds it. That demonstrates
advisory-lock bypass, **not** real lease expiry.

Retain stdout and stderr. A controller timeout means an unknown outcome; it does
not prove a remote worker or kernel operation stopped. The initial JSON profile
records the worker PID for cleanup. Restore connectivity before terminating
leftover workers and removing the disposable directory. Delete test instances,
mount targets and the EFS filesystem when finished; detached resources can still
incur charges. Provisioning needs an account, region, network and cost approval.

## Partition and lost-lock experiment

Use a fresh directory and two persistent SSH terminals. On each:

```sh
python3 -u /tmp/efs-probe.py worker /mnt/efs/imagepipe-efs-probe-RETURNED-ID
```

Each line is a JSON command. Save all replies and kernel logs. Keep the workers
alive and descriptors unchanged throughout the experiment.

| Step | Client | Command / action | Required observation |
| --- | --- | --- | --- |
| 1 | A | `{"op":"lock"}` then `{"op":"write","value":"A-before"}` | Locked, written |
| 2 | B | `{"op":"lock"}` | Busy |
| 3 | Operator | Isolate **all NFS traffic from A**, preserving control traffic | Packet counters show the cut; A's client cannot renew through another connection |
| 4 | B | Retry `{"op":"lock"}` until takeover, within a recorded experiment deadline | Eventually locked after actual expiry; no assumed fixed lease duration |
| 5 | B | `{"op":"write","value":"B-after-takeover"}` | Written; keep B's lock held |
| 6 | Operator | Restore A's NFS connectivity | Record exact time |
| 7 | A | `{"op":"write","value":"stale-A"}` | Candidate requires EIO on the original descriptor |
| 8 | A | `{"op":"rename_head","value":"stale-A"}` | Record outcome; namespace operations are not fenced by the anchor lock |
| 9 | B | `{"op":"release"}`, `{"op":"lock"}`, `{"op":"read"}` | Must still read B-after-takeover after a fresh lock/cache-coherency boundary |

The operator chooses a narrowly scoped network fault mechanism for the actual
mount setup, including any TLS proxy. Do not merely pause the application:
the kernel can keep renewing its NFS lease. Do not unlock, close, reopen, remount
or reacquire on A before step 7; those would test a different descriptor/stateid.
Do not enable automatic lost-lock recovery. Any late successful stale write or
change to B's record rejects the candidate. A timeout or failed takeover is
**inconclusive**, not a pass. Restore traffic even after failure.

Repeat with A issuing `write` while isolated so the syscall is already pending
when B takes over, then restore traffic. Verify no delayed A write overwrites B.
Repeat without takeover: a pending operation may complete after a controller
deadline while its authority is still valid. Record that outcome separately;
it exposes the cancellation/uncertain-commit contract that task `015.2` must solve.

## Uncertain publication and recovery

`{"op":"stage","value":"bytes"}` returns a generation token. On the same
worker, `{"op":"publish_crash"}` renames it and kills the process before
replying. Another client uses `{"op":"generation","token":"TOKEN"}` to
verify the complete generation. This is a deterministic lost-reply simulation,
not NFS RPC replay testing. The production design must resolve outcomes by
operation identity, never replay a stale authoritative replacement blindly.

Also run the partition experiment with traffic interrupted while synchronous
anchor writes are pending; retain EFS/client evidence of committed, failed and
unknown outcomes. A torn or checksummed-invalid anchor must require fresh source
validation. Probe record size is 4 KiB for the experiment; it establishes no
atomic-write guarantee or production format.

The remaining qualification matrix includes mount/server recovery, cross-client
directory-cache behavior under repeated publications, reader lifetime during
unlink, helper death with dirty I/O, and mount-unresponsive resource bounds.
These need actual target-system fault injection; the smoke is a starting harness.

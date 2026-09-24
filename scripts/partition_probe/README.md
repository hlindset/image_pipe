# Owned-partition protocol probe

Run the deterministic local-filesystem schedules:

```sh
mise exec -- python3 -m unittest discover -s scripts/partition_probe -v
```

Uses disposable temporary directories and Python's standard library. `protocol.py`
is a stepwise protocol prototype, not the SharedFileSystem adapter. No production
cache path should be passed to it. Tests use real rename, link, open and unlink
operations, with deliberate scheduling boundaries instead of sleeps.

The suite explores publication and adoption cut points, target/source retirement,
copy fallback, pre-opened readers, stale discovery, repeated cleanup, crashes
represented by abandoned staging, and uncertain publication/retirement results.
It also completes a rename through directory descriptors opened before retirement
to model a filesystem operation already resolved by the kernel. A negative control
shows why recursive recreation of an incarnation root breaks retirement.

The reader acquires the complete small test body into memory and checks its digest
before returning a hit. This is an executable safety witness, not a production
recommendation to hash/buffer every response. Production stable paths, streaming,
digest strategy and resource budgets belong to the subsequent implementation.
Keys are fixed test constants and discovery is an unbounded test helper.

Local results establish behavior only on the filesystem running the tests. They
do not simulate cross-client caches, power loss, an unresponsive kernel mount,
NFS recovery, SMB sharing modes, or every possible syscall schedule. The protocol
argument and remaining qualification requirements are in the
[retirement protocol](../../docs/plans/shared-cache-retirement-protocol.md).

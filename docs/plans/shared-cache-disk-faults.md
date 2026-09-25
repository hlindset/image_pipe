# Shared-cache disk fault tests

Run the production Elixir adapter against a disposable small filesystem:

```sh
bash scripts/shared-cache-disk-faults.sh
```

The macOS runner creates a 16 MiB FAT sparse disk image, mounts it under a unique
temporary directory, runs the opt-in `shared_disk_fault` tests, and detaches and
removes the image on exit. If detachment fails, it preserves the directory and
prints its location for cleanup. It never fills the host filesystem.

Alternatively, provide an already mounted **disposable** filesystem of at most
32 MiB that rejects hard links, on a different device from the system temporary directory:

```sh
IMAGE_PIPE_FAULT_VOLUME=/path/to/disposable-volume mise exec -- mix test \
  test/image_pipe/cache/shared_file_system/disk_fault_test.exs --include shared_disk_fault
```

These tests intentionally exhaust that filesystem's free space. They check the
device and capacity before writing, bound filler writes to 32 MiB, and remove
their own randomly named directories after each test. They are excluded from the
ordinary suite because they need this dedicated mount.

Coverage:

- Real `EXDEV` from hard-link creation selects copy fallback; copied bytes and
  metadata remain usable after the original writer is removed.
- Same-filesystem hard-link rejection also selects copying and preserves the
  complete generation after its original writer is removed.
- Real `ENOSPC` during adoption leaves no published generation, cleans staging,
  releases its resource reservation, and preserves the original body.
- A full shared volume still permits a real Plug request to return the expected
  encoded image dimensions and pixels, without a published output entry.
- Pressure eviction can use previous reports and free retained storage even when
  a full volume prevents new inventory and usage publication.
- Helper loss while a cross-device FIFO-backed copy is incomplete keeps the
  destination unpublished and preserves its uncertain resource charge.

On 2026-09-25 all six passed on a local macOS FAT disk image. The initial four tests
for cross-device copying, full-storage fail-open delivery, failed adoption, and
interrupted copying also passed on HFS+. The ordinary generation
suite covers reconciliation when a link call returns an error but its completed
destination exists, including loss of the original name. This proves those local
error paths. It does not qualify NFS/SMB visibility, cross-machine operation,
power-loss durability, or every hard-link error code. Shared-mount qualification
remains `image_plug-015.8`.

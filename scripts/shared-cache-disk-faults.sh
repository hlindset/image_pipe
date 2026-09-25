#!/usr/bin/env bash
set -euo pipefail

# A real small filesystem gives EXDEV and ENOSPC without filling the host disk.
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/image-pipe-disk-faults.XXXXXX")
mount_path="$scratch/volume"
mounted=false

cleanup() {
  if "$mounted"; then
    if ! hdiutil detach "$mount_path"; then
      echo "Detach failed; preserving test volume at $scratch" >&2
      return
    fi
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$mount_path"
hdiutil create -size 16m -fs MS-DOS -volname IPFAULT -type SPARSE "$scratch/disk.sparseimage"
mounted=true
hdiutil attach "$scratch/disk.sparseimage" -mountpoint "$mount_path" -nobrowse
IMAGE_PIPE_FAULT_VOLUME="$mount_path" mise exec -- mix test \
  test/image_pipe/cache/shared_file_system/disk_fault_test.exs --include shared_disk_fault

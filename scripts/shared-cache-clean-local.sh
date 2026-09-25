#!/bin/sh
set -eu

# Run only between complete deployment shutdown and successor startup.
# --stopped asserts that the BEAM and every helper have terminated and been reaped.
if [ "$#" -ne 2 ] || [ "$1" != "--stopped" ]; then
  echo "Usage: $0 --stopped /absolute/dedicated/local_root" >&2
  exit 64
fi

root=$2
while :; do
  case "$root" in
    /) break ;;
    */) root=${root%/} ;;
    */.) root=${root%/.} ;;
    *) break ;;
  esac
done
case "$root" in
  /*) ;;
  *) echo "local_root must be absolute" >&2; exit 64 ;;
esac
if [ -L "$root" ]; then
  echo "local_root must not be a symlink" >&2
  exit 64
fi
if [ ! -e "$root" ]; then exit 0; fi
if [ ! -d "$root" ]; then
  echo "local_root must be a dedicated directory" >&2
  exit 64
fi
physical=$(cd "$root" && pwd -P)
if [ "$physical" = / ]; then
  echo "local_root must be a dedicated directory" >&2
  exit 64
fi
ls -A -- "$root" >/dev/null

# Preflight the entire root before deleting anything. Shared roots, unrelated
# files, and symlink-managed directories do not have this layout.
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then continue; fi
  name=${entry##*/}
  case "$name" in
    *[!0-9a-f]*) echo "Unexpected entry in local_root: $name" >&2; exit 65 ;;
  esac
  if [ "${#name}" -ne 32 ] || [ ! -d "$entry" ] || [ -L "$entry" ]; then
    echo "Unexpected entry in local_root: $name" >&2
    exit 65
  fi
done

for entry in "$root"/*; do
  if [ ! -e "$entry" ]; then continue; fi
  rm -rf -- "$entry"
done

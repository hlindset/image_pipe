#!/usr/bin/env bash
# Prints the body of a version's section in image_pipe/CHANGELOG.md, the text
# between its `## X.Y.Z` heading and the next `## ` heading. Fails when the
# section is missing or empty.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: $0 VERSION}"

notes="$(awk -v version="$version" '
  /^## / {
    if (in_section) exit
    in_section = ($2 == version)
    next
  }
  in_section { print }
' "$root/image_pipe/CHANGELOG.md" | sed -e '/./,$!d')"

if [[ -z "${notes//[[:space:]]/}" ]]; then
  echo "image_pipe/CHANGELOG.md has no notes under \"## $version\"" >&2
  exit 1
fi

printf '%s\n' "$notes"

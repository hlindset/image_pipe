#!/usr/bin/env bash
# Prints a version's release notes. For the libraries, combines the
# image_pipe_url and image_pipe changelogs, grouped by project. For the server,
# prints its changelog's notes and the image_pipe version it releases with.
# Fails when a changelog is missing notes for that version.
#
# Usage: changelog-notes.sh libraries|server VERSION
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-}"
version="${2:-}"

if [[ -z "$version" || ! "$target" =~ ^(libraries|server)$ ]]; then
  echo "usage: $0 libraries|server VERSION" >&2
  exit 1
fi

notes() {
  local notes
  notes="$(awk -v version="$version" '
    /^## / {
      if (in_section) exit
      in_section = ($2 == "[" version "]")
      next
    }
    /^\[[^]]+\]:/ { if (in_section) exit }
    in_section { print }
  ' "$root/$1/CHANGELOG.md" | sed -e '/./,$!d')"

  if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "$1/CHANGELOG.md has no notes under \"## [$version]\"" >&2
    exit 1
  fi

  echo "$notes"
}

case "$target" in
  libraries)
    for project in image_pipe_url image_pipe; do
      section="$(notes "$project")"
      printf '## %s\n\n%s\n\n' "$project" "$section"
    done
    ;;
  server)
    pinned="$("$root/scripts/check-versions.sh" server-libraries)"
    section="$(notes image_pipe_server)"
    printf '%s\n\nBuilt with image_pipe and image_pipe_url %s.\n' "$section" "$pinned"
    ;;
esac

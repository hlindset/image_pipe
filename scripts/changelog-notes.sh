#!/usr/bin/env bash
# Combines a version's notes from all three project changelogs, grouped by
# project. Fails when a project is missing notes for that version.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: $0 VERSION}"

sections=()
for project in image_pipe_url image_pipe image_pipe_server; do
  notes="$(awk -v version="$version" '
    /^## / {
      if (in_section) exit
      in_section = ($2 == "[" version "]")
      next
    }
    /^\[[^]]+\]:/ { if (in_section) exit }
    in_section { print }
  ' "$root/$project/CHANGELOG.md" | sed -e '/./,$!d')"

  if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "$project/CHANGELOG.md has no notes under \"## [$version]\"" >&2
    exit 1
  fi

  sections+=("$(printf '## %s\n\n%s' "$project" "$notes")")
done

printf '%s\n\n' "${sections[@]}"

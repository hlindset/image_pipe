#!/usr/bin/env bash
# Checks that image_pipe_url, image_pipe, and image_pipe_server declare the same
# @version, and prints it. With an argument, also requires that version (a
# release tag without its leading "v").
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
expected="${1:-}"
version=""

for project in image_pipe_url image_pipe image_pipe_server; do
  found="$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/$project/mix.exs")"

  if [[ -z "$found" ]]; then
    echo "$project/mix.exs has no @version" >&2
    exit 1
  fi

  if [[ -z "$version" ]]; then
    version="$found"
  elif [[ "$found" != "$version" ]]; then
    echo "$project is $found but image_pipe_url is $version" >&2
    exit 1
  fi
done

if [[ -n "$expected" && "$expected" != "$version" ]]; then
  echo "expected version $expected, projects declare $version" >&2
  exit 1
fi

echo "$version"

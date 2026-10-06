#!/usr/bin/env bash
# Checks the project versions and prints one of them.
#
# image_pipe_url and image_pipe share one version. image_pipe_server shares
# their major.minor and has its own patch version. The image_pipe version the
# server releases with (@image_pipe_version) shares that major.minor and is no
# newer than the libraries.
#
# Usage: check-versions.sh [libraries|server|server-libraries] [VERSION]
#
# Prints the libraries' version, the server's, or the image_pipe version the
# server releases with. With VERSION (a release tag's version, without its
# prefix), also requires that version.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-libraries}"
expected="${2:-}"

attribute() {
  local value
  value="$(sed -n "s/^  @$2 \"\(.*\)\"$/\1/p" "$root/$1/mix.exs")"

  if [[ -z "$value" ]]; then
    echo "$1/mix.exs has no @$2" >&2
    exit 1
  fi

  echo "$value"
}

minor() { cut -d. -f1,2 <<< "$1"; }

# Whether version $1 is newer than $2, for versions that share major.minor. A
# release is newer than its own pre-releases.
newer() {
  local patch1 patch2
  patch1="$(cut -d. -f3 <<< "${1%%-*}")"
  patch2="$(cut -d. -f3 <<< "${2%%-*}")"

  if ((patch1 != patch2)); then
    ((patch1 > patch2))
  elif [[ "$1" == "$2" || "$1" == *-* && "$2" != *-* ]]; then
    return 1
  elif [[ "$2" == *-* && "$1" != *-* ]]; then
    return 0
  else
    [[ "$(printf '%s\n' "${1#*-}" "${2#*-}" | sort -V | tail -n 1)" == "${1#*-}" ]]
  fi
}

url="$(attribute image_pipe_url version)"
libraries="$(attribute image_pipe version)"
server="$(attribute image_pipe_server version)"
pinned="$(attribute image_pipe_server image_pipe_version)"

if [[ "$url" != "$libraries" ]]; then
  echo "image_pipe_url is $url but image_pipe is $libraries" >&2
  exit 1
fi

if [[ "$(minor "$server")" != "$(minor "$libraries")" ]]; then
  echo "image_pipe_server is $server but the libraries are $libraries; they must share major.minor" >&2
  exit 1
fi

if [[ "$(minor "$pinned")" != "$(minor "$libraries")" ]]; then
  echo "image_pipe_server releases with image_pipe $pinned but the libraries are $libraries; they must share major.minor" >&2
  exit 1
fi

if newer "$pinned" "$libraries"; then
  echo "image_pipe_server releases with image_pipe $pinned, newer than the libraries' $libraries" >&2
  exit 1
fi

case "$target" in
  libraries) version="$libraries" ;;
  server) version="$server" ;;
  server-libraries) version="$pinned" ;;
  *)
    echo "usage: $0 [libraries|server|server-libraries] [VERSION]" >&2
    exit 1
    ;;
esac

if [[ -n "$expected" && "$expected" != "$version" ]]; then
  echo "expected $target version $expected, found $version" >&2
  exit 1
fi

echo "$version"

#!/usr/bin/env bash
# Checks that the Erlang and Elixir versions pinned outside mise.toml match it:
# the newest CI matrix rows, the lint workflow's tools and cache keys, and the
# server's build image. Names each file that differs, so a bump in mise.toml
# lists what else to update.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

tool() {
  local value
  value="$(sed -n "s/^$1 = \"\(.*\)\"$/\1/p" "$root/mise.toml")"

  if [[ -z "$value" ]]; then
    echo "mise.toml has no $1" >&2
    exit 1
  fi

  echo "$value"
}

erlang="$(tool erlang)"
elixir="$(tool elixir)"
failed=0

# Requires $2 to appear at least $3 times in file $1.
expect() {
  local count
  count="$(grep -cF -- "$2" "$root/$1" || true)"

  if ((count < $3)); then
    echo "$1: expected $2 (Erlang $erlang, Elixir $elixir from mise.toml)" >&2
    failed=1
  fi
}

expect .github/workflows/elixir.yml "elixir: $elixir, erlang: \"$erlang\"" 2
expect .github/workflows/svg.yml "elixir: $elixir, erlang: \"$erlang\"" 1
expect .github/workflows/lint.yml "erlang = \"$erlang\"" 1
expect .github/workflows/lint.yml "elixir = \"$elixir\"" 1
expect .github/workflows/lint.yml "erlang$erlang-elixir${elixir/-otp-/-otp}-" 5
expect image_pipe_server/Dockerfile "hexpm/elixir:${elixir%%-otp-*}-erlang-$erlang-" 1

exit "$failed"

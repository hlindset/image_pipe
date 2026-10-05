#!/usr/bin/env bash
# Claude Code SessionStart hook — prepares a cloud session's checkout.
#
# Runs only in Claude Code on the web (CLAUDE_CODE_REMOTE=true); local sessions
# exit immediately. The cloud environment's setup script installs mise; this
# hook does the steps that need the repository:
#   - trusts mise.toml and installs its pinned toolchain, including bd
#   - installs Hex and rebar for the pinned Elixir
#   - runs `mise run setup` (deps for every project, fiddle assets)
#   - clones the beads database from origin's refs/dolt/data (`bd bootstrap`
#     is a no-op once the database exists)
#
# Stdout of a SessionStart hook becomes session context, so all output goes to
# .cloud-setup.log. Failures are non-fatal: the session still starts, and the
# log says which step failed.
set -uo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}" || exit 0
LOGFILE=".cloud-setup.log"

# The session proxy only allows the GitHub API for repositories in the
# session's scope, so mise's attestation checks for tool releases get a 403.
# LANG keeps Elixir from warning about a non-UTF-8 locale.
export MISE_AQUA_GITHUB_ATTESTATIONS=false
export MISE_GITHUB_GITHUB_ATTESTATIONS=false
export LANG="${LANG:-C.UTF-8}"
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# Variables written to CLAUDE_ENV_FILE apply to every Bash command in the
# session, so mise-managed tools resolve without `mise exec`.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export MISE_AQUA_GITHUB_ATTESTATIONS=false"
    echo "export MISE_GITHUB_GITHUB_ATTESTATIONS=false"
    echo "export LANG=\"$LANG\""
    echo "export PATH=\"$PATH\""
  } >> "$CLAUDE_ENV_FILE"
fi

run() {
  echo "==> $*" >> "$LOGFILE"
  "$@" >> "$LOGFILE" 2>&1 || echo "!! failed: $*" >> "$LOGFILE"
}

if command -v mise >/dev/null 2>&1; then
  run mise trust --yes
  run mise install
  run mise exec -- mix local.hex --force
  run mise exec -- mix local.rebar --force
  run mise run setup
else
  echo "!! mise not installed; add it to the cloud environment's setup script" >> "$LOGFILE"
fi

if command -v bd >/dev/null 2>&1; then
  run bd bootstrap --yes
else
  echo "!! bd not installed; mise install should have installed it" >> "$LOGFILE"
fi

exit 0

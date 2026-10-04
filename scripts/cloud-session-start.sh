#!/usr/bin/env bash
# Claude Code SessionStart hook — prepares a cloud session's checkout.
#
# Runs only in Claude Code on the web (CLAUDE_CODE_REMOTE=true); local sessions
# exit immediately. The cloud environment's setup script installs mise and bd;
# this hook does the steps that need the repository:
#   - trusts mise.toml and installs its pinned toolchain
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
export PATH="$HOME/.local/bin:$PATH"
LOGFILE=".cloud-setup.log"

run() {
  echo "==> $*" >> "$LOGFILE"
  "$@" >> "$LOGFILE" 2>&1 || echo "!! failed: $*" >> "$LOGFILE"
}

if command -v mise >/dev/null 2>&1; then
  run mise trust --yes
  run mise install
  run mise run setup
else
  echo "!! mise not installed; add it to the cloud environment's setup script" >> "$LOGFILE"
fi

if command -v bd >/dev/null 2>&1; then
  run bd bootstrap --yes
else
  echo "!! bd not installed; add it to the cloud environment's setup script" >> "$LOGFILE"
fi

exit 0

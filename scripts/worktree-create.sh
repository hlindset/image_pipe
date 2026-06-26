#!/usr/bin/env bash
# Claude Code WorktreeCreate hook — creates the worktree and runs setup.
#
# Contract:
#   - Receives JSON on stdin with 'name' field
#   - Must print the absolute worktree path on stdout (nothing else!)
#   - Progress output goes to /dev/tty
#
# What this does for image_plug:
#   - Creates/attaches the git worktree
#   - APFS copy-on-write clones deps/ and _build/ (root + fiddle) so Elixir
#     doesn't recompile from scratch. pnpm is skipped — its global content store
#     makes `pnpm install` near-instant, and node_modules symlinks don't clone
#     cleanly.
#   - Trusts mise in the new worktree (otherwise every `mise exec` prompts)
#   - Runs `mix deps.get` in root and fiddle to reconcile the cloned deps/
set -euo pipefail

INPUT=$(cat)
NAME=$(echo "$INPUT" | jq -r '.name')
REPO_PATH="$CLAUDE_PROJECT_DIR"
WORKTREE_PATH="${REPO_PATH}/.claude/worktrees/${NAME}"
BRANCH="worktree-${NAME}"

# Progress goes to /dev/tty — stdout is reserved for Claude
TTY=/dev/tty
log() { echo "$*" > "$TTY" 2>/dev/null || true; }

log "Creating worktree (branch: $BRANCH)..."

# --- Create the git worktree ---
# IMPORTANT: redirect git output away from stdout — Claude parses stdout for the path
mkdir -p "${REPO_PATH}/.claude/worktrees"
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git worktree add "$WORKTREE_PATH" "$BRANCH" >/dev/null 2>&1
else
  git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD >/dev/null 2>&1
fi

# --- APFS copy-on-write clone of build artifacts ---
# `cp -c` forces clonefile(2): instant, no extra disk until the copies diverge.
# Same-volume only, which holds since worktrees live under the repo.
log "  Cloning deps/ and _build/ (copy-on-write)..."
COW_DIRS=("deps" "_build" "fiddle/deps" "fiddle/_build")
for d in "${COW_DIRS[@]}"; do
  if [ -d "${REPO_PATH}/$d" ] && [ ! -e "${WORKTREE_PATH}/$d" ]; then
    cp -Rc "${REPO_PATH}/$d" "${WORKTREE_PATH}/$d" 2>/dev/null \
      || cp -R "${REPO_PATH}/$d" "${WORKTREE_PATH}/$d"
  fi
done

# --- Reconcile dependencies ---
# A fresh worktree's mise.toml is untrusted; trust it so `mise run` won't prompt.
# `mise run setup` then reconciles the cloned deps/ against mix.lock for root +
# fiddle, installs pnpm packages, and builds the fiddle assets (needed before the
# fiddle's mix tests can find the Vite manifest).
LOGFILE="${WORKTREE_PATH}/.worktree-setup.log"
SETUP_ERRORS=()

log "  Trusting mise..."
(cd "$WORKTREE_PATH" && mise trust) >> "$LOGFILE" 2>&1 || SETUP_ERRORS+=("'mise trust' failed")

log "  Running mise setup (deps + assets)..."
(cd "$WORKTREE_PATH" && mise run setup) >> "$LOGFILE" 2>&1 \
  || SETUP_ERRORS+=("'mise run setup' failed")

# --- Done ---
if [ ${#SETUP_ERRORS[@]} -gt 0 ]; then
  log "Setup completed with errors:"
  printf '  - %s\n' "${SETUP_ERRORS[@]}" > "$TTY" 2>/dev/null || true
  log "See $LOGFILE for details."
else
  log "Worktree ready."
fi

# Tell Claude where the worktree is — THE ONLY THING ON STDOUT
echo "$WORKTREE_PATH"

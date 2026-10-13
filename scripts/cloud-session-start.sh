#!/usr/bin/env bash
# Claude Code SessionStart hook — prepares a cloud session's checkout.
#
# Runs only in Claude Code on the web (CLAUDE_CODE_REMOTE=true); local sessions
# exit immediately. The cloud environment's setup script installs mise; this
# hook does the steps that need the repository:
#   - trusts mise.toml and installs its pinned toolchain, including bd
#   - installs Hex and rebar for the pinned Elixir
#   - runs `mise run setup` (deps for every project, fiddle assets)
#   - installs the DoltHub key from DOLTHUB_CREDS_JWK (set in the cloud
#     environment's settings) as Dolt's active credential
#   - restricts .beads to 0700, as bd expects
#   - clones the beads database from the DoltHub remote in .beads/config.yaml
#     (`bd bootstrap` is a no-op once the database exists)
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

# Dolt reads the active key from ~/.dolt/config_global.json ("user.creds") and
# loads ~/.dolt/creds/<key id>.jwk, where the key id is the SHA-512/224 hash
# of the public key in Dolt's base32 alphabet. Dolt's .jwk files keep the
# public key in "d" and the private key in "x" (dolt creds/jwk.go).
install_dolthub_creds() {
  python3 - <<'PY'
import base64, hashlib, json, os

jwk_text = os.environ["DOLTHUB_CREDS_JWK"].strip()
pub = base64.urlsafe_b64decode(json.loads(jwk_text)["d"])
std = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
dolt = "0123456789abcdefghijklmnopqrstuv"
digest = hashlib.new("sha512_224", pub).digest()
kid = base64.b32encode(digest).decode().rstrip("=").translate(str.maketrans(std, dolt))

home = os.path.expanduser("~/.dolt")
os.makedirs(os.path.join(home, "creds"), mode=0o700, exist_ok=True)
path = os.path.join(home, "creds", kid + ".jwk")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(jwk_text)

config_path = os.path.join(home, "config_global.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except (OSError, ValueError):
    config = {}
config["user.creds"] = kid
with open(config_path, "w") as f:
    json.dump(config, f)
print("installed DoltHub key " + kid)
PY
}

if [ -n "${DOLTHUB_CREDS_JWK:-}" ]; then
  run install_dolthub_creds
else
  echo "!! DOLTHUB_CREDS_JWK not set; bd can't sync with DoltHub" >> "$LOGFILE"
fi

# The clone leaves .beads at 0755, and bd warns on every command until it's
# 0700.
run chmod 700 .beads

if command -v bd >/dev/null 2>&1; then
  run bd bootstrap --yes
else
  echo "!! bd not installed; mise install should have installed it" >> "$LOGFILE"
fi

exit 0

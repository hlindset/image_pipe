#!/usr/bin/env bash
# Claude Code SessionStart hook — prepares a cloud session's checkout.
#
# Runs only in Claude Code on the web (CLAUDE_CODE_REMOTE=true); local sessions
# exit immediately. The cloud environment's setup script installs mise; this
# hook does the steps that need the repository:
#   - builds the libvips that CI's Elixir workflow builds, with JPEG XL, on
#     a libheif that writes AVIF orientation, and points vix at it (vix's
#     precompiled libvips can't read or write JPEG XL)
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

# libvips: the version, checksum, and packages match .github/workflows/elixir.yml,
# which this reads VIPS_VERSION and VIPS_SHA256 from. vix compiles against the
# build when VIX_COMPILATION_MODE is PLATFORM_PROVIDED_LIBVIPS, so it is set
# only once a build that reads JPEG XL is in place.
#
# libheif is built too, at the version Debian trixie ships to the server
# image: Ubuntu 24.04's libheif 1.17.6 drops an AVIF's orientation when the
# AV1 encoder doesn't pad the image. HEIF_SHA256 is the SHA-256 of the release
# tarball, which upstream doesn't publish.
HEIF_VERSION="1.19.8"
HEIF_SHA256="6c4a5b08e6eae66d199977468859dea3b5e059081db8928f7c7c16e53836c906"
vips_setting() {
  sed -n "s/^ *$1: \"\(.*\)\"$/\1/p" .github/workflows/elixir.yml | head -n 1
}
VIPS_VERSION="$(vips_setting VIPS_VERSION)"
VIPS_SHA256="$(vips_setting VIPS_SHA256)"
VIPS_PREFIX="$HOME/.cache/image_pipe/vips-$VIPS_VERSION-heif-$HEIF_VERSION"
SUDO=""
[ "$(id -u)" = "0" ] || SUDO="sudo"

vips_ready() {
  LD_LIBRARY_PATH="$VIPS_PREFIX/lib" "$VIPS_PREFIX/bin/vips" -l 2>/dev/null | grep jxlload >/dev/null
}

install_vips_build_deps() {
  $SUDO apt-get update &&
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential meson ninja-build cmake pkg-config xz-utils \
      libglib2.0-dev libexpat1-dev libjpeg-turbo8-dev libpng-dev \
      libwebp-dev libtiff-dev libgif-dev librsvg2-dev \
      liborc-0.4-dev liblcms2-dev libjxl-dev libcgif-dev libexif-dev \
      libimagequant-dev libaom-dev libsharpyuv-dev
}

build_vips() {
  local src status
  src="$(mktemp -d)" || return 1
  (
    set -e
    export PKG_CONFIG_PATH="$VIPS_PREFIX/lib/pkgconfig"
    cd "$src"
    tarball="libheif-${HEIF_VERSION}.tar.gz"
    curl -fsSL -o "$tarball" \
      "https://github.com/strukturag/libheif/releases/download/v${HEIF_VERSION}/${tarball}"
    echo "${HEIF_SHA256}  ${tarball}" | sha256sum --check --strict
    tar xzf "$tarball"
    cmake -S "libheif-${HEIF_VERSION}" -B heif-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$VIPS_PREFIX" \
      -DCMAKE_INSTALL_LIBDIR=lib -DWITH_EXAMPLES=OFF -DWITH_GDK_PIXBUF=OFF \
      -DBUILD_TESTING=OFF -DWITH_LIBDE265=OFF -DWITH_X265=OFF \
      -DWITH_OpenH264_DECODER=OFF -DWITH_DAV1D=OFF
    cmake --build heif-build
    cmake --install heif-build

    tarball="vips-${VIPS_VERSION}.tar.xz"
    curl -fsSL -o "$tarball" \
      "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/${tarball}"
    echo "${VIPS_SHA256}  ${tarball}" | sha256sum --check --strict
    tar xJf "$tarball"
    cd "vips-${VIPS_VERSION}"
    meson setup build --prefix="$VIPS_PREFIX" --libdir=lib --buildtype=release \
      -Dimagequant=enabled
    meson compile -C build
    meson install -C build
  )
  status=$?
  rm -rf "$src"
  vips_ready || { rm -rf "$VIPS_PREFIX"; return 1; }
  return "$status"
}

if [ -z "$VIPS_VERSION" ] || [ -z "$VIPS_SHA256" ]; then
  echo "!! VIPS_VERSION or VIPS_SHA256 missing from .github/workflows/elixir.yml" >> "$LOGFILE"
elif ! vips_ready; then
  run install_vips_build_deps
  run build_vips
fi

if vips_ready; then
  export VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS
  export PKG_CONFIG_PATH="$VIPS_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export LD_LIBRARY_PATH="$VIPS_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    {
      echo "export VIX_COMPILATION_MODE=$VIX_COMPILATION_MODE"
      echo "export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH\""
      echo "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\""
    } >> "$CLAUDE_ENV_FILE"
  fi
  # A vix already compiled against its precompiled libvips doesn't rebuild
  # when the mode changes.
  for vix in ./*/_build/*/lib/vix; do
    if [ -d "$vix/priv/precompiled_libvips" ]; then rm -rf "$vix"; fi
  done
else
  echo "!! libvips build unavailable; vix uses its precompiled libvips, which lacks JPEG XL" >> "$LOGFILE"
fi

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

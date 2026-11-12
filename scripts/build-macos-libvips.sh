#!/bin/sh
# Builds libvips for local development on an Apple silicon Mac without
# Homebrew: `mise run libvips:macos`.
#
# vix's precompiled libvips lacks JPEG XL, and Homebrew's vips formula installs
# about a hundred formulae, half of them for loaders ImagePipe doesn't use.
# This installs the libraries in scripts/macos-libvips/pixi.toml from
# conda-forge into one environment under ~/.cache/image_pipe/ and builds
# libvips into it, at the version and checksum .github/workflows/elixir.yml
# gives. It needs the Xcode command line tools for the compiler.
#
# Run it again after that version or pixi.toml changes.
set -eu

if [ "$(uname -sm)" != "Darwin arm64" ]; then
  echo "This builds libvips for macOS on Apple silicon only." >&2
  exit 1
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
vips_setting() {
  sed -n "s/^ *$1: \"\(.*\)\"$/\1/p" "$repo/.github/workflows/elixir.yml" | head -n 1
}
VIPS_VERSION="$(vips_setting VIPS_VERSION)"
VIPS_SHA256="$(vips_setting VIPS_SHA256)"
if [ -z "$VIPS_VERSION" ] || [ -z "$VIPS_SHA256" ]; then
  echo "VIPS_VERSION or VIPS_SHA256 missing from .github/workflows/elixir.yml" >&2
  exit 1
fi

# The environment lives outside the repository, so worktrees share it.
root="$HOME/.cache/image_pipe/libvips-macos"
env="$root/.pixi/envs/default"
mkdir -p "$root"
cp "$repo/scripts/macos-libvips/pixi.toml" "$root/pixi.toml"
(cd "$root" && mise exec pixi@latest -- pixi install)

src="$(mktemp -d)"
trap 'rm -rf "$src"' EXIT
cd "$src"
tarball="vips-${VIPS_VERSION}.tar.xz"
curl -fsSL -o "$tarball" \
  "https://github.com/libvips/libvips/releases/download/v${VIPS_VERSION}/${tarball}"
echo "${VIPS_SHA256}  ${tarball}" | shasum -a 256 -c -
tar xJf "$tarball"
cd "vips-${VIPS_VERSION}"

export PATH="$env/bin:$PATH"
export PKG_CONFIG_PATH="$env/lib/pkgconfig:$env/share/pkgconfig"
# conda-forge names its libraries @rpath/libfoo.dylib, so libvips and its
# tools carry the path to them.
export LDFLAGS="-Wl,-rpath,$env/lib"
meson setup build --prefix="$env" --libdir=lib --buildtype=release \
  -Dimagequant=enabled -Dcgif=enabled -Djpeg-xl=enabled -Dheif=enabled \
  -Dintrospection=disabled -Dexamples=false -Dcplusplus=false
meson compile -C build
meson install -C build

"$env/bin/vips" --version
cat <<NOTE

libvips is in $env

Point vix at it in mise.local.toml:

  [env]
  VIX_COMPILATION_MODE = "PLATFORM_PROVIDED_LIBVIPS"
  VIX_LIBVIPS_PREFIX = "{{env.HOME}}/.cache/image_pipe/libvips-macos/.pixi/envs/default"
  PKG_CONFIG = "{{env.HOME}}/.cache/image_pipe/libvips-macos/.pixi/envs/default/bin/pkg-config"

Then rebuild vix in each project and environment that uses it:

  MIX_ENV=test mise exec -- mix deps.compile vix --force
NOTE

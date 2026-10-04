#!/usr/bin/env bash
# Starts an image_pipe_server container with a read-only root filesystem and
# checks /health, a PNG request, and a JPEG XL source (which needs the libvips
# the image builds from source).
#
#     test/container/smoke.sh IMAGE [vision]
#
# With `vision`, the configuration requires the detector, so the container
# only becomes healthy when the image bundles it.
set -euo pipefail

image=$1
variant=${2:-base}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
name="image-pipe-smoke-$$"
port=${SMOKE_PORT:-18080}

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/images"
cp "$here/../support/images/pic.png" "$here/pic.jxl" "$work/images/"
cp "$here/config.toml" "$work/config.toml"

if [ "$variant" = "vision" ]; then
  printf '\n[processing]\ndetector_required = true\n' >> "$work/config.toml"
fi

docker run -d --name "$name" --read-only --tmpfs /tmp \
  -p "127.0.0.1:${port}:8080" \
  -v "$work/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$work/images:/data/images:ro" \
  "$image" >/dev/null

status=starting
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo exited)
  [ "$status" = "healthy" ] || [ "$status" = "exited" ] && break
  sleep 1
done

if [ "$status" != "healthy" ]; then
  echo "container did not become healthy ($status)" >&2
  docker logs "$name" >&2 || true
  exit 1
fi

curl -fsS "http://127.0.0.1:${port}/health" | grep -qx ok

if docker logs "$name" 2>&1 | grep -q 'WARNING'; then
  echo "the server logged a warning at startup" >&2
  docker logs "$name" >&2
  exit 1
fi

check_png() {
  local source=$1
  local content_type
  content_type=$(curl -fsS -o "$work/out.png" -w '%{content_type}' \
    "http://127.0.0.1:${port}/w=4/format=png/src/${source}")
  [ "$content_type" = "image/png" ] || {
    echo "${source}: unexpected content type: $content_type" >&2
    exit 1
  }
  [ "$(head -c 8 "$work/out.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ] || {
    echo "${source}: response is not a PNG" >&2
    exit 1
  }
}

check_png pic.png
check_png pic.jxl

echo "smoke test passed ($variant)"

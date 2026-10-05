#!/usr/bin/env bash
# Starts an image_pipe_server container with a read-only root filesystem and
# checks the health checks, a PNG request, a JPEG XL source (which needs the
# libvips the image builds from source), and draining on shutdown.
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

curl -fsS "http://127.0.0.1:${port}/health/live" | grep -qx ok
curl -fsS "http://127.0.0.1:${port}/health/ready" | grep -qx ok

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

# On SIGTERM the server reports not ready but keeps serving, and Docker sees
# the container turn unhealthy before it stops listening.
docker stop -t 30 "$name" >/dev/null &
stopping=$!
ready=200
for _ in $(seq 1 20); do
  ready=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health/ready" || true)
  [ "$ready" = "503" ] && break
  sleep 0.2
done
[ "$ready" = "503" ] || {
  echo "draining: /health/ready answered $ready, expected 503" >&2
  exit 1
}
check_png pic.png
health=starting
for _ in $(seq 1 20); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo exited)
  [ "$health" = "unhealthy" ] && break
  sleep 0.25
done
[ "$health" = "unhealthy" ] || {
  echo "draining: container health is $health, expected unhealthy" >&2
  exit 1
}
wait "$stopping"

# An invalid configuration stops the server with one line naming the setting.
printf '[sources.photos]\nadapter = "file"\nroot = "/data/images"\n' > "$work/invalid.toml"
set +e
output=$(docker run --rm --read-only --tmpfs /tmp \
  -v "$work/invalid.toml:/etc/image_pipe/config.toml:ro" "$image" 2>&1)
exit_status=$?
set -e
[ "$exit_status" = 1 ] \
  && grep -qx 'invalid configuration: sources.photos.match: required' <<<"$output" \
  && ! grep -Eq 'crash|\*\*' <<<"$output" || {
  echo "invalid configuration: unexpected exit status $exit_status or output:" >&2
  echo "$output" >&2
  exit 1
}

echo "smoke test passed ($variant)"

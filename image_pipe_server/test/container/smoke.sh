#!/usr/bin/env bash
# Starts an image_pipe_server container with a read-only root filesystem and
# checks the health checks, each output format, a JPEG XL source (which needs
# the libvips the image builds from source), an SVG source (which needs the
# image_pipe_svg NIF), the cache stats (which read disk space with df),
# draining on shutdown, the start script's port, CPU, and allocator settings,
# and the VM's process limit.
#
#     test/container/smoke.sh IMAGE [vision]
#
# With `vision`, the configuration requires the detector, so the container
# only becomes healthy when the image bundles it, and a second container
# without a network checks that detection needs no downloads.
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
printf '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>' \
  > "$work/images/pic.svg"
cp "$here/config.toml" "$work/config.toml"

if [ "$variant" = "vision" ]; then
  printf '\n[processing]\ndetector_required = true\n' >> "$work/config.toml"
fi

# The CA store Erlang loads lacks the emSign roots Mozilla removed, and keeps
# emSign Root CA - G1, so the check can't pass on an empty store.
cacerts=$(docker run --rm --entrypoint /app/bin/image_pipe_server "$image" eval '
  names = ["emSign ECC Root CA - G3", "emSign Root CA - C1", "emSign ECC Root CA - C3", "emSign Root CA - G1"]
  for {:cert, der, _} <- :public_key.cacerts_get(), name <- names, :binary.match(der, name) != :nomatch,
    do: IO.puts(name)')
[ "$cacerts" = "emSign Root CA - G1" ] || {
  echo "CA store: expected only emSign Root CA - G1 among the emSign roots, found:" >&2
  echo "$cacerts" >&2
  exit 1
}

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

# The configuration serves unsigned URLs on purpose, which the server warns
# about; any other warning or error fails the test.
if docker logs "$name" 2>&1 | grep -E '\[(warning|error|critical|alert|emergency)\]' |
  grep -v 'serves unsigned URLs' | grep -q .; then
  echo "the server logged a warning at startup" >&2
  docker logs "$name" >&2
  exit 1
fi

# Requests SOURCE as FORMAT and checks the content type and the file
# signature in the first 12 bytes.
check_output() {
  local format=$1 source=$2
  local content_type header signature
  content_type=$(curl -fsS -o "$work/out" -w '%{content_type}' \
    "http://127.0.0.1:${port}/w=4/format=${format}/src/${source}")
  [ "$content_type" = "image/${format}" ] || {
    echo "${source} as ${format}: unexpected content type: $content_type" >&2
    exit 1
  }
  header=$(head -c 12 "$work/out" | od -An -tx1 | tr -d ' \n')
  case "$format" in
    png) signature='89504e470d0a1a0a*' ;;
    jpeg) signature='ffd8ff*' ;;
    webp) signature='52494646????????57454250' ;;
    avif) signature='????????6674797061766966' ;;
  esac
  # shellcheck disable=SC2053
  [[ $header == $signature ]] || {
    echo "${source} as ${format}: the response doesn't start like a ${format} file: $header" >&2
    exit 1
  }
}

check_png() { check_output png "$1"; }

check_png pic.png
check_png pic.jxl
check_png pic.svg
check_output jpeg pic.png
check_output webp pic.png
check_output avif pic.png

stats_status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/stats")
[ "$stats_status" = "401" ] || {
  echo "stats: answered $stats_status without the token, expected 401" >&2
  exit 1
}
stats=$(curl -fsS -H "Authorization: Bearer smoke-stats-token-0123456789abcdef" "http://127.0.0.1:${port}/stats")
for expected in '"misses":6' '"disk_total_bytes":[0-9]'; do
  printf '%s' "$stats" | grep -q "$expected" || {
    echo "stats: the response lacks $expected: $stats" >&2
    exit 1
  }
done

# The environment the start script gave the VM in a container.
beam_env() {
  docker exec "$1" sh -c \
    'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = beam.smp ] && tr "\0" "\n" < $p/environ; done; true'
}

# The server runs on jemalloc, whose background thread returns memory while
# the server is idle. Without a CPU limit it gets one arena per core.
beam_env=$(beam_env "$name")
cores=$(docker exec "$name" nproc)
for expected in LD_PRELOAD=/usr/local/lib/libjemalloc.so.2 \
  "MALLOC_CONF=background_thread:true,narenas:$cores,dirty_decay_ms:1000"; do
  printf '%s\n' "$beam_env" | grep -qx "$expected" || {
    echo "allocator: the server's environment lacks $expected" >&2
    exit 1
  }
done

# Under a CPU limit, jemalloc gets one arena per CPU of the limit, rounded up.
malloc_conf=$(docker run --rm --cpus 1.5 --entrypoint sh "$image" -c '. /app/releases/*/env.sh && echo "$MALLOC_CONF"')
[ "$malloc_conf" = "background_thread:true,narenas:2,dirty_decay_ms:1000" ] || {
  echo "allocator: under a 1.5-CPU limit, MALLOC_CONF is $malloc_conf" >&2
  exit 1
}

# On SIGTERM the server reports not ready but keeps serving for the
# configured shutdown_delay (15 s), and Docker sees the container turn
# unhealthy before it stops listening. A slow runner can take seconds to
# deliver SIGTERM, so each wait allows 10 s and reports how long it took.
docker stop -t 30 "$name" >/dev/null &
stopping=$!
stop_sent=$SECONDS
ready=200
for _ in $(seq 1 50); do
  ready=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health/ready" || true)
  [ "$ready" = "503" ] && break
  sleep 0.2
done
[ "$ready" = "503" ] || {
  echo "draining: /health/ready answered $ready $((SECONDS - stop_sent)) s after docker stop, expected 503" >&2
  docker logs "$name" >&2 || true
  exit 1
}
echo "draining: readiness failed $((SECONDS - stop_sent)) s after docker stop"
check_png pic.png
health=starting
for _ in $(seq 1 40); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo exited)
  [ "$health" = "unhealthy" ] && break
  sleep 0.25
done
[ "$health" = "unhealthy" ] || {
  echo "draining: container health is $health $((SECONDS - stop_sent)) s after docker stop, expected unhealthy" >&2
  exit 1
}
echo "draining: container unhealthy $((SECONDS - stop_sent)) s after docker stop"
wait "$stopping"

# With a JSON log format, every line is JSON, including the ones dependencies
# log while they start. The server listens on another port, so the container
# only turns healthy when the health check follows IPS_SERVER__PORT.
docker run -d --name "$name-json" --read-only --tmpfs /tmp \
  -e IPS_TELEMETRY__LOG_FORMAT=json -e IPS_SERVER__PORT=9090 \
  -v "$work/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$work/images:/data/images:ro" \
  "$image" >/dev/null
trap 'docker rm -f "$name-json" >/dev/null 2>&1 || true; cleanup' EXIT

status=starting
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$name-json" 2>/dev/null || echo exited)
  [ "$status" = "healthy" ] || [ "$status" = "exited" ] && break
  sleep 1
done
json_logs=$(docker logs "$name-json" 2>&1)
docker rm -f "$name-json" >/dev/null
[ "$status" = "healthy" ] && grep -q 'CA(s)' <<<"$json_logs" &&
  ! grep -qv '^{' <<<"$json_logs" || {
  echo "log format: the json server logged a line that isn't JSON (status $status):" >&2
  echo "$json_logs" >&2
  exit 1
}

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

# With distribution on, the console works inside the container, and epmd and
# the node listen on loopback only, so only the HTTP port is open beyond it.
# The same container checks the health check on a separate health port, and
# the start script's settings for a CPU quota and for glibc's allocator.
docker run -d --name "$name-dist" --read-only --tmpfs /tmp --cpus 1.5 \
  -e RELEASE_DISTRIBUTION=sname -e RELEASE_COOKIE=smoke-test-cookie \
  -e IPS_SERVER__HEALTH_PORT=9091 -e IPS_SERVER__HEALTH_BIND=127.0.0.1 \
  -e IMAGE_PIPE_ALLOCATOR=glibc \
  -v "$work/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$work/images:/data/images:ro" \
  "$image" >/dev/null
trap 'docker rm -f "$name-dist" >/dev/null 2>&1 || true; cleanup' EXIT

rpc=
for _ in $(seq 1 60); do
  rpc=$(docker exec "$name-dist" bin/image_pipe_server rpc 'IO.puts(:pong)' 2>/dev/null || true)
  [ "$rpc" = "pong" ] && break
  sleep 1
done
[ "$rpc" = "pong" ] || {
  echo "distribution: rpc from inside the container failed" >&2
  docker logs "$name-dist" >&2 || true
  exit 1
}

# vm.args lowers the process limit from the VM's default of 1,048,576.
limit=$(docker exec "$name-dist" bin/image_pipe_server rpc 'IO.puts(:erlang.system_info(:process_limit))')
[ "$limit" = 262144 ] || {
  echo "process limit: expected 262144, got $limit" >&2
  exit 1
}

status=starting
for _ in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$name-dist" 2>/dev/null || echo exited)
  [ "$status" = "healthy" ] || [ "$status" = "exited" ] && break
  sleep 1
done
[ "$status" = "healthy" ] || {
  echo "health port: the container did not become healthy ($status)" >&2
  docker logs "$name-dist" >&2 || true
  exit 1
}

# A 1.5-CPU quota rounds up to two libvips threads, and glibc's allocator
# runs with two arenas and without jemalloc preloaded.
beam_env=$(beam_env "$name-dist")
for expected in VIPS_CONCURRENCY=2 MALLOC_ARENA_MAX=2; do
  printf '%s\n' "$beam_env" | grep -qx "$expected" || {
    echo "start script: the server's environment lacks $expected" >&2
    exit 1
  }
done
if printf '%s\n' "$beam_env" | grep -q '^LD_PRELOAD=.*jemalloc'; then
  echo "start script: IMAGE_PIPE_ALLOCATOR=glibc still preloads jemalloc" >&2
  exit 1
fi

# /proc/net/tcp lists listening sockets (state 0A) as hex address:port.
# 0100007F is 127.0.0.1 and 1F90 is port 8080.
exposed=$(docker exec "$name-dist" cat /proc/net/tcp /proc/net/tcp6 2>/dev/null |
  awk '$4 == "0A" { split($2, a, ":"); if (a[1] !~ /^(0100007F|0000000000000000FFFF00000100007F|00000000000000000000000001000000)$/ && a[2] != "1F90") print $2 }')
[ -z "$exposed" ] || {
  echo "distribution: sockets listening beyond loopback: $exposed" >&2
  exit 1
}

# The vision image carries its models, so detection works without a network.
# The container has none, so it's queried from inside. A required detector
# whose models are missing fails `detect` requests with 503, and a
# smart-face crop falls back to attention, which the response marks
# `no-store`.
if [ "$variant" = "vision" ]; then
  docker rm -f "$name-dist" >/dev/null
  docker run -d --name "$name-offline" --network none --read-only --tmpfs /tmp \
    -v "$work/config.toml:/etc/image_pipe/config.toml:ro" \
    -v "$work/images:/data/images:ro" \
    "$image" >/dev/null
  trap 'docker rm -f "$name-dist" "$name-offline" >/dev/null 2>&1 || true; cleanup' EXIT

  status=starting
  for _ in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$name-offline" 2>/dev/null || echo exited)
    [ "$status" = "healthy" ] || [ "$status" = "exited" ] && break
    sleep 1
  done
  [ "$status" = "healthy" ] || {
    echo "offline detection: container did not become healthy ($status)" >&2
    docker logs "$name-offline" >&2 || true
    exit 1
  }

  for options in "detect=face" "detect=car" "anchor=smart-face"; do
    response=$(docker exec "$name-offline" curl -sS -o /dev/null -D - \
      -w 'response: %{http_code} %{content_type}' \
      "http://127.0.0.1:8080/w=2/h=4/fit=cover/${options}/format=png/src/pic.png") ||
      response="curl failed ($?)"
    grep -qx 'response: 200 image/png' <<<"$response" &&
      ! grep -qi '^cache-control:.*no-store' <<<"$response" || {
      echo "offline detection: ${options} answered:" >&2
      echo "$response" >&2
      docker logs "$name-offline" >&2 || true
      exit 1
    }
  done
fi

echo "smoke test passed ($variant)"

#!/bin/bash
# Starts the prod release as the image ships it (vm.args, env.sh), with an
# allocator A/B: ALLOC=jemalloc (shipped default) | glibc2 (MALLOC_ARENA_MAX=2,
# shipped fallback) | glibc (glibc defaults).
# Usage: run.sh NAME [extra env assignments...]
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
REL=${REL:-/home/user/image_pipe/.claude/worktrees/agent-a6052be7146ed379e/image_pipe_server/_build/prod/rel/image_pipe_server}
name=$1; shift
export LD_LIBRARY_PATH=/root/.cache/image_pipe/vips-8.18.7-heif-1.19.8/lib
export IPS_CONFIG=$L/config.toml
export RELEASE_DISTRIBUTION=sname
export RELEASE_NODE=memload@localhost
export RELEASE_COOKIE=memhunt
export LANG=C.UTF-8
case "${ALLOC:-jemalloc}" in
  jemalloc) export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 MALLOC_CONF=${MALLOC_CONF:-background_thread:true} IMAGE_PIPE_ALLOCATOR=glibc ;;
  glibc2) export IMAGE_PIPE_ALLOCATOR=glibc ;;
  glibc) export IMAGE_PIPE_ALLOCATOR=glibc MALLOC_ARENA_MAX=${MALLOC_ARENA_MAX:-32} ;;
esac
for kv in "$@"; do export "$kv"; done
rm -rf $L/cache
mkdir -p $L/cache/output
exec $REL/bin/image_pipe_server start > $L/server_$name.log 2>&1

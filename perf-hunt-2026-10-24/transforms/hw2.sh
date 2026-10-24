#!/bin/bash
# usage: hw2.sh W file... ; modes from MODES env
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/perf
W=$1; shift
cd /home/user/image_pipe/.claude/worktrees/agent-a8713a86bb3c09c91/image_pipe
for f in "$@"; do
  for m in ${MODES:-decode thumb resize float pipeline}; do
    MIX_ENV=test mix run --no-start $S/hw2.exs $S/img/$f $m $W 2>&1 | grep "hw="
  done
done

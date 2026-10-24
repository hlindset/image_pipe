#!/bin/bash
# usage: batch.sh REPS FLAGS path1 path2 ...
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/perf
REPS=$1; shift
FLAGS=$1; shift
cd /home/user/image_pipe/.claude/worktrees/agent-a8713a86bb3c09c91/image_pipe
for p in "$@"; do
  MIX_ENV=test mix run $S/run.exs $S/img $REPS "$p" $FLAGS 2>&1 | grep -v -i "warning\|^ *│\|^ *$\|└\|┌" | tail -1
done

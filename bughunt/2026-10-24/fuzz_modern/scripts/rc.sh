#!/bin/bash
cd /home/user/image_pipe/image_pipe
F=/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/fuzz_modern
echo "=== $1"
S=$(date +%s.%N)
MIX_ENV=test timeout ${TO:-120} mix run --no-compile $F/scripts/run.exs "$@" > /tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/fuzz_modern/out/last.$$ 2>&1
E=$?
grep -E "^\[|RAISE|Segmentation|core|\*\*|error" $F/out/last.$$ | grep -v "^\s*$" | head -40
echo "EXIT=$E T=$(echo "$(date +%s.%N)-$S"|bc)"
rm -f $F/out/last.$$

#!/bin/bash
cd /home/user/image_pipe/image_pipe
F=/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/fuzz_modern
timeout 300 mix run --no-compile $F/scripts/mutfuzz.exs "$1" "${2:-200}" 2>&1 | grep -vE "warning|^\s*$"
echo "procexit=$?"

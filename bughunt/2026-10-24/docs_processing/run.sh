#!/bin/sh
# usage: run.sh path...
D=/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing
F=$D/cur.exs
echo 'Code.require_file("'$D'/h.exs")' > $F
for p in "$@"; do echo "H.show(\"$p\")" >> $F; done
cd /home/user/image_pipe/image_pipe && mix run $F 2>&1 | grep -E -- '->|error|Error' 

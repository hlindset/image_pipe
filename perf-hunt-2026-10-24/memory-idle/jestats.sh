#!/bin/sh
# usage: jestats.sh NODENAME  -> jemalloc global stats of that release's beam via gdb mallctl
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
P=$(pgrep -f "beam.*-sname $1@" | head -1)
[ -z "$P" ] && P=$(pgrep -f "beam.*$1@" | head -1)
echo "pid $P"
timeout 60 gdb -p "$P" -batch -x $S/jestats.gdb 2>&1 | grep -E '^(allocated|active|metadata|resident|mapped|retained|narenas|background)|rror' | awk '{ if ($2 > 100000) printf "%s %.2f MiB\n", $1, $2/1048576; else print }'

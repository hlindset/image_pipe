#!/bin/sh
# usage: anonmaps.sh NODENAME -> anon mappings sorted by RSS (size kB, rss kB, perms, addr)
P=$(pgrep -f "beam.*$1@" | head -1)
awk '/^[0-9a-f]+-[0-9a-f]+ /{addr=$1; perms=$2; name=$6; split($1,a,"-")} /^Size:/{size=$2} /^Rss:/{ if (name=="") print size, $2, perms, addr }' /proc/$P/smaps | sort -k2 -rn | head -${2:-25}
echo "stack-sized (8196 kB) mappings:"
awk '/^[0-9a-f]+-[0-9a-f]+ /{name=$6} /^Size:/{size=$2} /^Rss:/{ if (name=="" && (size==8192 || size==8196 || size==8200)) {n++; r+=$2} } END {print n, "mappings", r, "kB rss"}' /proc/$P/smaps

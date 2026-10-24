#!/bin/sh
# usage: memfd.sh NODENAME -> Rss/Pss of the JIT memfd mappings and smaps_rollup
P=$(pgrep -f "beam.*$1@" | head -1)
awk '/^[0-9a-f]+-[0-9a-f]+ /{m=($0 ~ /memfd/)} m && /^(Rss|Pss|Shared_Clean|Shared_Dirty|Private_Dirty):/ {a[$1]+=$2} END {for (k in a) print "memfd", k, a[k], "kB"}' /proc/$P/smaps
grep -E '^(Rss|Pss|Pss_Anon|Pss_File|Pss_Shmem):' /proc/$P/smaps_rollup | tr -s ' \n' ' '; echo

#!/bin/sh
# usage: load.sh URLFILE CONCURRENCY ROUNDS  -> prints status code histogram
F=$1; C=${2:-4}; R=${3:-1}
i=0
while [ $i -lt $R ]; do
  cat "$F"
  i=$((i+1))
done | xargs -P "$C" -n 1 curl -s -o /dev/null -w '%{http_code}\n' -H 'Accept: image/avif,image/webp,*/*' | sort | uniq -c

#!/bin/sh
# usage: phases.sh NAME PORT -> per-format warm-up phases, jemalloc + RSS after each (15 s idle)
S=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad
NAME=$1; PORT=$2
IPS_SERVER__PORT=$PORT $S/ctl.sh start "$NAME" "${3:-$S/min.toml}"
sleep 10
report() {
  echo "== $1"; $S/rss.sh "$NAME"; $S/jestats.sh "$NAME" | grep -E 'allocated|active|metadata|resident' | tr '\n' ' '; echo
}
report startup
phase() {
  label=$1; shift
  for f in beach.jpg dog.jpg mountain.jpg cooking.png alpha.png waterfall.jpg; do
    for op in "$@"; do echo "http://127.0.0.1:$PORT/$op/src/$f"; done
  done > $S/phase_$NAME.txt
  $S/load.sh $S/phase_$NAME.txt 4 2 > /dev/null
  sleep 20
  report "$label"
}
phase jpeg "w=400/format=jpeg" "w=800/format=jpeg" "w=1200/format=jpeg"
phase webp "w=400/format=webp" "w=800/format=webp"
phase png "w=400/format=png" "w=800/format=png"
phase avif "w=400/format=avif" "w=800/format=avif"
phase info "output=info,blurhash,lqip-css"
phase smart "w=400/h=400/fit=cover/anchor=smart/format=jpeg"
phase jpeg_again "w=400/format=jpeg" "w=800/format=jpeg" "w=1200/format=jpeg"

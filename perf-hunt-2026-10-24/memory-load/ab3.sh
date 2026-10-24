#!/bin/bash
# pool x VIPS_CONCURRENCY memory (for image_plug-da5b), shipped jemalloc config.
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
export PLAN="big 8 45;idle 10"
for r in 1 2; do
  for pv in "4 4" "4 2" "4 1" "2 4" "8 1" "8 4"; do
    set -- $pv
    ALLOC=jemalloc bash $L/scenario.sh "pv_p$1v$2_$r" IPS_POOL__MAX_CONCURRENCY=$1 VIPS_CONCURRENCY=$2
  done
done

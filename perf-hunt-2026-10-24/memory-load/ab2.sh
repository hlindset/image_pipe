#!/bin/bash
# jemalloc tuning A/B on the queued-burst phase (big c=8, pool 4) plus idle tail.
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
export PLAN="big 8 45;idle 15;big 8 45;idle 15"
for r in 1 2; do
  ALLOC=jemalloc bash $L/scenario.sh "b_je$r"
  ALLOC=jemalloc MALLOC_CONF=background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:0 bash $L/scenario.sh "b_jed1k$r"
  ALLOC=jemalloc MALLOC_CONF=background_thread:true,dirty_decay_ms:0,muzzy_decay_ms:0 bash $L/scenario.sh "b_jed0$r"
  ALLOC=jemalloc MALLOC_CONF=background_thread:true,narenas:4 bash $L/scenario.sh "b_jen4$r"
  ALLOC=jemalloc MALLOC_CONF=background_thread:true,narenas:4,dirty_decay_ms:1000,muzzy_decay_ms:0 bash $L/scenario.sh "b_jen4d$r"
  ALLOC=glibc2 bash $L/scenario.sh "b_g2$r"
done

#!/bin/bash
# Allocator A/B, two rounds, same deterministic URL sequence per phase.
L=/tmp/claude-0/-home-user-image-pipe/d9301eaf-e830-533b-9e40-eef149fee684/scratchpad/load
export PLAN="mix 4 60;idle 20;big 8 45;idle 20;autoq 4 40;idle 30"
for r in 1 2; do
  ALLOC=jemalloc bash $L/scenario.sh "abje$r"
  ALLOC=jemalloc MALLOC_CONF=background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:0 bash $L/scenario.sh "abjed$r"
  ALLOC=glibc2 bash $L/scenario.sh "abg2$r"
  ALLOC=glibc bash $L/scenario.sh "abg$r"
done

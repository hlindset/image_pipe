What: rel/env.sh preloads jemalloc with `MALLOC_CONF=background_thread:true` and nothing else. jemalloc then creates 4 arenas per CPU it sees (+1), and it counts CPUs from the affinity mask, not the cgroup quota, so a container limited to 2 CPUs on a 64-core host gets 257 arenas. Threads (4 BEAM schedulers, dirty schedulers, VIPS_CONCURRENCY workers per pipeline, async) are spread round-robin over arenas, so each arena keeps its own partly used slabs and its own metadata after a burst. env.sh already derives VIPS_CONCURRENCY from the quota for the same reason.

Where: image_pipe_server/rel/env.sh (jemalloc block, `export MALLOC_CONF=...`).

Measured (local prod release, OTP 29.1.1, Debian jemalloc 5.3 preloaded as env.sh does, minimal TOML with one file source, 4-CPU box). Warm-up: 637 requests at concurrency 4 over 49 sample images (resize/crop/blur/sharpen/rotate/pixelate/trim, jpeg/png/webp/avif, smart crop, info+blurhash+lqip), then 45 s idle so background_thread decays dirty pages. jemalloc stats read with gdb `mallctl("stats.*")` after `epoch`:

| MALLOC_CONF | narenas | idle RSS after warm-up | jemalloc resident | active | allocated | metadata |
|---|---|---|---|---|---|---|
| background_thread:true (shipped) | 17 | 146.7 / 148.4 MiB (2 runs) | 50.0 / 48.0 | 36.8 / 34.9 | 26.0 / 24.5 | 13.7 / 13.7 |
| + narenas:4 | 5 | 142.6 / 141.8 | 45.5 / 44.4 | 34.1 / 33.0 | 26.3 / 25.5 | 11.9 / 11.9 |
| + narenas:64 (what a 16-core host gets) | 65 | 154.3 | 60.8 | 39.9 | 25.9 | 21.3 |

Live allocations are the same (~26 MiB); the difference is fragmentation (active minus allocated) and per-arena metadata. On this 4-CPU box the shipped config costs ~4 MiB idle over narenas = CPUs; on a 16-core host ~16 MiB, growing with core count until every thread has its own arena (36 threads at peak here; more with a bigger pool). Startup idle (before any request) is unchanged (~27-30 MiB jemalloc resident either way).

Repro: `MALLOC_CONF=background_thread:true,narenas:4 bin/image_pipe_server daemon`, warm up, wait 45 s, then
`gdb -p <pid> -batch -ex 'set $b=(unsigned long*)malloc(64)' -ex 'set $l=(unsigned long*)malloc(8)' -ex 'set *$l=8' -ex 'call (int)mallctl("epoch",0,0,$b,8)' -ex 'call (int)mallctl("stats.resident",$b,$l,0,0)' -ex 'p *$b'` (repeat for stats.active/allocated/metadata, arenas.narenas).

Proposed fix: in env.sh, when MALLOC_CONF is unset, add `narenas:N` with N = the cgroup CPU quota (the value env.sh already computes for VIPS_CONCURRENCY), or the online CPU count without a quota; e.g. `MALLOC_CONF=background_thread:true${n:+,narenas:$n}`. Size: a few lines in env.sh plus a comment and server changelog entry. Risk: low; fewer arenas means more lock contention between threads, which jemalloc's tcache absorbs; check with the `perf` workflow that throughput doesn't move (4 arenas for 4 CPUs is still 1 per CPU).

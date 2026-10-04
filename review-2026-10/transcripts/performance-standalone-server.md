# Performance: standalone server

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:40Z

Performance: standalone server

## Claude · 2026-10-04T11:45:25Z

I found three changes to the server's Docker image that are worth making. Nothing is changed yet; tell me which ones to do. I couldn't build the image here, so I built the image's pinned libvips with the same flags and load-tested it.

1. **Use jemalloc instead of glibc's allocator.** Same workload: peak memory went from 2.6 GB to 1.3 GB, and memory still held after the load from 1.9 GB to 0.33 GB. Throughput didn't change. Setting `MALLOC_ARENA_MAX=2` gets most of that without a new dependency.
2. **Add `libhwy-dev` to the libvips build.** This turns on its faster SIMD backend and cuts CPU time by about 45% on resize, reduce and blur. That matters most for PNG, WebP, AVIF and JXL sources, where libvips can't shrink the image while decoding it.
3. **Add the dav1d AVIF decoder.** AVIF decoding was about 30% faster. The SVT-AV1 encoder was 3× slower than aom here, so don't add it.

Four smaller items I reasoned through but couldn't measure here:
- libvips ignores Kubernetes CPU limits when deciding how many threads to start, so it should get its thread count from the CPU limit.
- A default processing pool: unbounded requests used 3× the memory for the same throughput. This would turn overload into 503s, so it's your call.
- Garbage-collecting Bandit's connection process after every request.
- Turning off BEAM scheduler busy-waiting.

Full numbers, file:line refs and methodology: [standalone-server.md](/mnt/project-files/perf-review/standalone-server.md)

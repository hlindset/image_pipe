# Coordinated cache measurements

Run each command in a fresh VM, from the repository root:

```sh
mise exec -- mix run bench/coordinated_cache.exs two-pool
mise exec -- mix run bench/coordinated_cache.exs output-only
mise exec -- mix run bench/coordinated_cache.exs binary-source
mise exec -- mix run bench/cache_reads.exs streamed
mise exec -- mix run bench/cache_reads.exs binary
```

Each command emits one JSON result. The variant benchmark serves the repository's
10,671,398-byte `waterfall.jpg` from a local Bandit origin, with twelve variants:
1001×777 crops at three focus positions and output widths 127, 256, 511, and 801.
It uses concurrency four, empty filesystem pools for the cold traversal, then
repeats the same requests warm. Libvips' operation cache is disabled. The script
asserts cold/warm byte equivalence and reports hashes for cross-mode comparison.

`output-only` uses the coordinated lifecycle without retaining original bodies.
`binary-source` uses a benchmark-only adapter that buffers the original fully
before decoding, with only the response cache. All modes use the same image
operations and limits. This is a controlled comparison, not a production capacity
recommendation.

## Local sample, 2026-09-20

| Measurement | Two pools | Output only | Buffered source |
| --- | ---: | ---: | ---: |
| Cold origin downloads | 1 | 12 | 12 |
| Cold origin bytes | 10,671,398 | 128,056,776 | 128,056,776 |
| Warm origin bytes | 0 | 0 | 0 |
| Cold traversal, ms | 1,520.6 | 1,458.7 | 1,412.2 |
| Warm traversal, ms | 4.8 | 4.6 | 4.8 |
| Retained input body bytes | 10,671,398 | 0 | 0 |
| Output-pool body bytes, including source records | 365,466 | 366,674 | 364,862 |
| Sampled process RSS peak, bytes | 825,851,904 | 846,462,976 | 1,022,590,976 |
| Libvips tracked memory peak, bytes | 54,485,402 | 47,439,350 | 53,579,412 |

All twelve response hashes matched across all modes. All modes reported shrink
factors 2 and 4, plus unshrunk loads. The input pool saved eleven original
downloads (91.7% of origin bytes). This localhost run did not demonstrate a cold
latency improvement: disk staging, verification, and coordination have costs,
while a local origin has little network latency.

RSS includes the BEAM, local origin, Req, libvips, and Plug.Test's assembled
response bodies. It is sampled with `ps`; libvips reports its own allocation
high-water mark. These are single-run observations on a development machine,
not isolated statistical measurements or proof of a universal memory reduction.
Repeat under the deployment's source sizes, latency, concurrency, and working set
before selecting pool sizes.

## Large cached response reads

The separate read benchmark writes a 64 MiB JSON body incrementally, then consumes
the cached body into a digest without assembling a response in Plug.Test.
Both modes verify the complete size and digest before delivery. Streaming reads
the verified file again in bounded chunks; the binary convenience API assembles
the complete second read.

| Measurement | Streamed read | Binary read |
| --- | ---: | ---: |
| Body bytes | 67,108,866 | 67,108,866 |
| Largest delivered chunk | 65,536 | 67,108,866 |
| Read and digest, ms | 130.1 | 201.4 |
| Sampled RSS increase over post-write baseline, bytes | 147,456 | 125,534,208 |

Both produced SHA-256
`a5d7993dae17808f937ce4a62405d920b02d97a20aa82d2d4080dfaa01b1b15d`.
The memory result supports bounded-body delivery for this workload. It does not
measure network backpressure or every Plug adapter; integrity verification still
requires a full disk pass before headers, followed by the delivery pass.

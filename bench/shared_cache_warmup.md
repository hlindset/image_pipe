# Shared-cache inventory warmup

Local measurements on 2026-09-25, Darwin, Elixir 1.20.4 / OTP 29.
The benchmark compares an empty location index with one seeded from partition
inventories. Each trial acquires and verifies every 16 KiB body, then repeats
the same lookups against the now-hot index. Three trials per mode alternate
execution order. Modules and one representative lookup are preloaded equally;
the location index and partition-list cache are reset before measurement.

| Writer partitions / keys | Mode | First lookup median / p95 | Hot lookup median / p95 | Warmup median | First pass median |
| --- | --- | --- | --- | --- | --- |
| 8 / 64 | Disk discovery | 24.70 / 28.14 ms | 0.83 / 1.14 ms | — | 1,584.66 ms |
| 8 / 64 | Inventory hints | 0.83 / 1.10 ms | 0.81 / 1.03 ms | 19.19 ms | 53.95 ms |
| 32 / 128 | Disk discovery | 84.35 / 93.10 ms | 0.86 / 1.20 ms | — | 10,996.43 ms |
| 32 / 128 | Inventory hints | 0.91 / 1.19 ms | 0.82 / 1.03 ms | 36.81 ms | 121.16 ms |

First-lookup percentiles pool individual key timings across trials. Pass and
warmup medians summarize whole trials; first-pass times exclude warmup.
Raw samples: [8 partitions](shared_cache_warmup_samples.json) and
[32 partitions](shared_cache_warmup_32_samples.json).

For N keys and P writer partitions, each disk-first trial submitted one partition
listing, N candidate-discovery operations and N reader acquisitions. Warmup
submitted one partition listing, P inventory reads and N generation-metadata
reads. Its first pass, and both modes' hot passes, submitted only N reader
acquisitions. These are traced isolated-I/O submissions, not filesystem syscalls
or server RPCs; internal resource cleanup is outside those counts. Candidate
discovery enumerates directories across partitions and currently launches a
directory helper per listing, making its cost sensitive to partition count.

This is a favorable inventory-coverage case: all requested keys are inventoried,
lookups are serial, and the OS page cache is warm. Adoption is disabled by a
one-byte retention budget. Timings include local reader acquisition, body reading,
digest verification and release; they exclude HTTP delivery and transformation.
Warmup completes before measured requests, so these results do not measure its
contention with concurrent traffic. They demonstrate the value of hints for
listed keys, not a general hit-rate improvement or a qualified NFS/SMB profile.
Shared-mount runs must additionally cover partial inventory coverage, concurrent
requests, publication/adoption, cleanup and cold storage caches before tuning
production defaults.

Reproduce from the repository root:

```sh
mise exec -- mix run bench/shared_cache_warmup.exs --output bench/shared_cache_warmup_samples.json
mise exec -- mix run bench/shared_cache_warmup.exs --partitions 32 --entries 128 --output bench/shared_cache_warmup_32_samples.json
```

Use `--root /path/on/mount` to choose the measured storage parent. The script
creates and removes its own uniquely named child directory; reader copies remain
node-local. `--entries`, `--partitions`, `--rounds` and `--bytes` control workload
size. The harness requires the shared-cache directory helper build toolchain.

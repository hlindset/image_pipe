# FileSystem cache startup scan

Run each `measure` in a fresh VM, from `image_pipe/`:

```sh
mise exec -- mix run bench/startup_scan.exs generate /path/c1m 1000000
mise exec -- mix run bench/startup_scan.exs measure /path/c1m --cold
mise exec -- mix run bench/startup_scan.exs measure /path/c1m --cold --unmarked
```

Each `measure` emits one JSON result. `counted_ms` is the time from starting the
instance until Admission has counted every entry, `scan_complete_ms` adds the
leftover sweep, and `snapshot` is what writing the index to a file on a clean
stop and loading it on the next start would cost instead. Generated bodies are
empty, so each entry costs two inodes and a 4 KiB block for its metadata.

## Cloud session sample, 2026-10-24

A Claude Code cloud session: 4 vCPUs (Xeon, 2.8 GHz), 15 GB RAM, ext4 on a
virtual disk, OTP 29 with the JIT, Elixir 1.20.4, `main` at 7402ee5. The cap is
128 KiB an entry, so nothing is evicted.

| Entries | Run | Counted, s | Sweep, s | Complete, s | RSS peak, GB | Index, MB |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1M | cold, 3 runs | 37.1–39.6 | 26.6–31.2 | 64.9–70.7 | 2.5–3.9 | 208 |
| 1M | warm, 2 runs | 33.9–38.7 | 24.6–26.5 | 58.4–65.2 | 3.9 | 208 |
| 1M | cold, unmarked | 36.7 | 292.7 | 329.4 | 2.2 | 208 |
| 2M | cold, 2 runs | 78.1–82.1 | 65.6–71.3 | 147.7–149.4 | 3.7 | 416 |

| Entries | Snapshot, MB | Write, s | Load, s |
| ---: | ---: | ---: | ---: |
| 1M | 95 | 1.1–1.4 | 1.1–1.2 |
| 2M | 190 | 2.6–2.9 | 2.5–3.4 |

A cold page cache costs no more than a warm one: the scan is bound by CPU in the
VM, not by the disk. Profiling the 1M cache in isolation:

| Step, 1M entries (2M names, 65,536 partitions) | Time, s |
| --- | ---: |
| List every partition in one process, discarding the names | 6.0 |
| The same, keeping every listing in that process | 58.8 |
| The same, keeping them, in a process with a 100M-word minimum heap | 8.6 |
| `Store.parse_body_filename/1` over every name | 14.7 |
| One `Regex.run/3` over every name, with the regex in a module attribute | 7.3 |
| `Sweep.run_listings/4` | 28.8 |

Keeping every listing in one process costs ten times the listing itself, and a
large minimum heap removes most of that, so the counting time goes to garbage
collecting that process's growing heap. The scan keeps every listing in its
process, and its RSS peak follows. The sweep classifies every name with regexes kept in module attributes,
which OTP 28 and later rebuild at every use. The unmarked run decodes every
metadata file, as the first start after a `@metadata_version` bump does.

A prototype that lists and parses each first-level partition group in its own
task, and inserts compact rows straight into a public ETS table, counts the
same caches in about a third of the time (`bench/startup_scan_floor.exs DIR`):

| Entries | Counted now, s | Prototype, s |
| ---: | ---: | ---: |
| 1M | 37.1–39.6 | 11.8 |
| 2M | 78.1–82.1 | 22.7 |

The prototype doesn't pair bodies with their metadata files or sweep.

# Perf hunt, 2026-10-24

Measurement scripts, profiles, logs and prototype diffs from the perf hunt
filed under beads epic `image_plug-dru3`, plus the Vix `mutate` reproduction
for `image_plug-o1pb`. They were written against `main` at 7402ee5 (0.4.0),
on a shared 4-CPU box with libvips 8.18.7. This branch isn't meant to be
merged.

Run the `.exs` scripts from `image_pipe/` with `MIX_ENV=test mix run <script>`
(add `--no-start` where a bead says so). Some take arguments or write to a
scratch directory; read the top of each script first. The A/B scripts read
`:persistent_term` flags (`:ip_prefetch`, `:ip_max_flights`, and similar)
that only the prototype edits check; on clean `main` they measure the
baseline only.

| Directory | Area | Beads |
|---|---|---|
| `request-path/` | Per-request overhead: parse, representation, 304, cache hits, telemetry. `prof304.txt` and `fprof_304.txt` are profiles of a 304. | dru3.2, dru3.7, dru3.8, dru3.9 |
| `transforms/` | Decode and transform time and libvips memory high-water. `prep.exs <dir>` builds the test images from `priv/static/images/mountain.jpg` (they aren't committed). | dru3.1, dru3.4, dru3.12, dru3.15, dru3.16 |
| `output/` | Encoder options, opaque alpha, autoquality breakdown and reference overlap. | dru3.3, dru3.5, dru3.6, dru3.11, dru3.13 |
| `concurrency/` | Slow-client and burst load tests over Bandit. `prototypes.diff` holds the flag-gated coordinator prefetch prototype (dru3.10) and the flight-cap toggle (dru3.14). `slow1.log` is a slow-client run. | dru3.10, dru3.14 |
| `memory-idle/` | Idle footprint of a local prod release with the shipped `env.sh` and `vm.args`. `ctl.sh` starts and stops the node, `measure.exs` and `jestats.sh` take the readings, `load.sh` runs the warm-up, and `min.toml` and `cache.toml` are the two configs. `bead_*.md` are the filed bead bodies. | dru3.17, dru3.18, dru3.19, 646g |
| `memory-load/` | Memory under sustained load on a local prod release. `run.sh` starts it with an allocator variant, `scenario.sh` runs the load phases, `drive.exs` is the load driver and `sampler.exs` the per-second sampler. `ab*.sh` are the allocator, jemalloc tuning and pool × `VIPS_CONCURRENCY` comparisons. Each `out_*/` has the `samples.csv` and `phases.log` of one run. `prep.sh` builds the source images (they aren't committed). | dru3.20, dru3.21, da5b |
| `vix-mutate/` | `mut.exs` shows `mutate` editing an in-memory original. `race.exs` reproduces the concurrent sRGB-check race; `race2.exs` and `race3.exs` interleave its steps by hand. | o1pb |

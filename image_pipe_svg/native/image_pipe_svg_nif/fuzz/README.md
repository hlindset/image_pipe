# Fuzzing the SVG parser

cargo-fuzz targets for the code that reads untrusted SVGs: the checks that
run before parsing, the parse itself, the cost estimate, and rendering. They
compile the NIF's `src/` modules directly, without the rustler layer, whose
`cdylib` can't link with libFuzzer.

| Target | Feeds | Fails when |
| --- | --- | --- |
| `render` | raw bytes, parsed, estimated, and rendered at 64×64 within the default budget | anything panics, overflows its 64 MB stack, runs past the timeout, or uses more than 1 GB |
| `expansion` | raw bytes that pass the element limit | usvg builds more than 4 nodes per element the limit counted |
| `templates` | bytes placed where usvg copies content (entity values, markers, `objectBoundingBox` clip paths, masks and patterns, `feImage`, embedded SVGs, `<use>`, stylesheets), repeated up to 10,200 times | as `render` |

Run them with nightly Rust and cargo-fuzz:

```sh
rustup toolchain install nightly
cargo +nightly install cargo-fuzz
cargo +nightly fuzz run -O -s none render corpus/render seeds/render -- \
  -max_len=65536 -timeout=10 -rss_limit_mb=1024 -malloc_limit_mb=1024 \
  -max_total_time=1200
```

`-O` builds without debug assertions, as the NIF is built. tiny-skia 0.12
asserts in debug builds that curve points are finite, which some SVGs
break, but release builds render them (`seeds/render/nonfinite_curve`).
`-s none` turns off AddressSanitizer, which fails to link on macOS and adds
little for this safe Rust. Don't build while a target runs: replacing a
running target's binary kills it with SIGILL on macOS. `seeds/` holds the cases from the PR #856 reviews
and a few ordinary SVGs; `python3 seeds.py` writes them again. libFuzzer
keeps the inputs it finds in `corpus/` and failing ones in `artifacts/`,
both ignored by git. Add a minimized failing input to `seeds/` once it's
fixed, so the next run starts from it.

CI runs each seed once on stable Rust, without cargo-fuzz. The targets build
with the `fuzzing` cfg that cargo-fuzz would set:

```sh
RUSTFLAGS="--cfg fuzzing" cargo build --release --bins
target/release/render -runs=0 -timeout=10 seeds/render
```

A stack overflow on the 64 MB thread kills the target before libFuzzer can
save the input. Set `FUZZ_LAST_INPUT` to a file path, and each target
writes every input there before running it, so the file holds the culprit.
On macOS the crash report in `~/Library/Logs/DiagnosticReports/` has the
backtrace.

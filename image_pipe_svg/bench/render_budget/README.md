# Render budget benchmark

Pathological SVGs (blurs, nested layers, chained masks, repeated image draws,
`<use>` and entity bombs) for checking image_pipe_svg's render budget.

Generate the cases, then compare the NIF's work estimate with real render
time. Run from `image_pipe_svg/`:

```sh
python3 bench/render_budget/gen.py /tmp/cases
mix run bench/render_budget/calibrate.exs /tmp/cases
```

`calibrate.exs` prints each case's estimated work and peak pixels, its render
time, and the milliseconds per million work units, which sets how long the
default `max_render_work` (250M) takes on that machine. The
[SVG render budget calibration](../../../.github/workflows/svg-bench.yml)
workflow runs it on CI hardware, on pull requests that change this directory
and by hand.

The Rust harness in `src/` times resvg on its own, outside the NIF:

```sh
cargo build --release
./target/release/svgbench /tmp/cases/blur_s10.svg 4000
```

`results.txt` holds one harness run on an Apple M-series laptop, with peak RSS
from `/usr/bin/time -l` and a 60 s cutoff ("terminated abnormally").

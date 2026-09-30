"""Fresh-VM feasibility samples for yx6; run through mise exec -- python3.

Each pair alternates execution order. Output includes every raw sample and medians.
This is a decode/resize microbenchmark, not a full HTTP request benchmark.
"""

import argparse
import json
import os
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--trials", type=int, default=3)
    parser.add_argument("--source", default="priv/static/images/waterfall.jpg")
    parser.add_argument("--rate", type=int, action="append", dest="rates",
                        help="MiB/s; 0 means unthrottled; repeat for a sweep")
    parser.add_argument("--shrink", type=int, choices=(1, 2, 4, 8), action="append", dest="shrinks")
    parser.add_argument("--auto", action="store_true", help="Include the prefix-based selector")
    args = parser.parse_args()
    samples = []
    summaries = []
    for rate in args.rates or (0, 20):
        for shrink in args.shrinks or (1, 8):
            case = []
            for trial in range(args.trials):
                ordered_modes = ["spool", "overlap", "auto"] if args.auto else ["spool", "overlap"]
                modes = ordered_modes if trial % 2 == 0 else list(reversed(ordered_modes))
                for mode in modes:
                    with tempfile.TemporaryDirectory(prefix="image-pipe-overlap-") as tmp:
                        result = subprocess.run(
                            ["mix", "run", "--no-compile", "--preload-modules",
                             "bench/source_overlap.exs", mode, args.source, str(rate), str(shrink)],
                            capture_output=True, text=True, timeout=120,
                            env=os.environ | {"TMPDIR": tmp},
                        )
                    if result.returncode:
                        raise RuntimeError(result.stdout + result.stderr)
                    rows = [json.loads(line) for line in result.stdout.splitlines()
                            if line.startswith('{"')]
                    assert len(rows) == 1, result.stdout
                    row = dict(rows[0], trial=trial)
                    case.append(row)
                    samples.append(row)
                    print(f"{rate=} {shrink=} {mode}: {row['total_ms']:.1f}ms", flush=True)
            assert len({r["pixel_sha256"] for r in case}) == 1, "pixels differ"
            assert len({r["source_sha256"] for r in case}) == 1, "source bytes differ"
            medians = {
                mode: {key: statistics.median(r[key] for r in case if r["mode"] == mode)
                       for key in ("total_ms", "rss_peak_bytes", "libvips_peak_bytes")}
                for mode in ordered_modes
            }
            summaries.append({"rate_mib_s": rate, "shrink": shrink, "medians": medians,
                              "speedup_percent": 100 * (1 - medians["overlap"]["total_ms"] /
                                                        medians["spool"]["total_ms"])})
            args.output.write_text(json.dumps({"platform": platform.platform(), "samples": samples,
                                              "summaries": summaries}, indent=2) + "\n")
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()

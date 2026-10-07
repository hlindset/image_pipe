"""Summarize JSONL from autoquality_crossover.exs, using medians per case."""

import collections
import json
import math
import statistics
import sys


def geomean(values):
    return math.exp(statistics.mean(math.log(value) for value in values))


def summarize(path):
    with open(path, encoding="utf-8") as source:
        rows = [json.loads(line) for line in source]
    environment = rows[0]
    samples = [row for row in rows if row["kind"] == "sample"]
    cases = collections.defaultdict(lambda: collections.defaultdict(list))
    for row in samples:
        key = (row["source"], row["label"], tuple(row["dimensions"]), row["format"])
        cases[key][row["scorer"]].append(row)

    pairs = []
    for key, modes in cases.items():
        pair = {}
        for mode in ("full", "crop"):
            trials = modes[mode]
            assert len(trials) == environment["repeats"], (key, mode)
            assert len({row["body_sha256"] for row in trials}) == 1, (key, mode)
            assert len({row["quality"] for row in trials}) == 1, (key, mode)
            assert len({row["truth"] for row in trials}) == 1, (key, mode)
            pair[mode] = {
                **trials[0],
                "elapsed_us": statistics.median(row["elapsed_us"] for row in trials),
            }
        pairs.append(pair)

    print(path)
    print(json.dumps(environment, sort_keys=True))
    print(f"{len(pairs)} cases; {len(samples)} timed mode samples")
    print("MP format cases full_ms crop_ms speedup bytes_ratio score_delta misses")
    for size in environment["sizes"]:
        for fmt in environment["formats"]:
            selected = [
                pair
                for pair in pairs
                if pair["full"]["format"] == fmt
                and min(
                    environment["sizes"],
                    key=lambda mp: abs(mp - pair["full"]["megapixels"]),
                )
                == size
            ]
            if not selected:
                continue
            speeds = [p["full"]["elapsed_us"] / p["crop"]["elapsed_us"] for p in selected]
            byte_ratios = [p["crop"]["bytes"] / p["full"]["bytes"] for p in selected]
            deltas = [p["crop"]["truth"] - p["full"]["truth"] for p in selected]
            misses = [p for p in selected if missed(p)]
            full_ms = statistics.median(p["full"]["elapsed_us"] for p in selected) / 1000
            crop_ms = statistics.median(p["crop"]["elapsed_us"] for p in selected) / 1000
            print(
                f"{size:g} {fmt} {len(selected)} {full_ms:.0f} {crop_ms:.0f} "
                f"{geomean(speeds):.2f} {geomean(byte_ratios):.3f} "
                f"{statistics.median(deltas):+.2f} {len(misses)}"
            )

    for pair in pairs:
        if missed(pair):
            full, crop = pair["full"], pair["crop"]
            print(
                "MISS",
                full["source"],
                full["label"],
                full["format"],
                full["dimensions"],
                f"full={full['truth']:.4f} crop={crop['truth']:.4f}",
            )


def missed(pair):
    full, crop = pair["full"], pair["crop"]
    floor = full["target"] - full["allowed_error"]
    return full["truth"] >= floor and crop["truth"] < floor


for input_path in sys.argv[1:]:
    summarize(input_path)

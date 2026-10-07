"""Validate adaptive tile measurements and compare per-case median wall times."""

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
    cases = collections.defaultdict(lambda: collections.defaultdict(list))
    for row in rows[1:]:
        assert row["kind"] == "sample"
        result = row["result"]
        coords = row["locations"]
        assert len(coords) == len({tuple(c) for c in coords}) <= 32
        assert result["encodes"] <= 12
        assert result["references"] <= len(coords)
        assert result["comparisons"] <= result["encodes"] * result["references"]
        assert len(result["rounds"]) <= 5
        counts = [r["tiles"] for r in result["rounds"]]
        assert counts == sorted(set(counts))
        assert counts[-1] == result["tiles"]
        nested = {value["tiles"]: value["score"] for value in row["nested"]}
        assert abs(nested[result["tiles"]] - result["score"]) < 1e-9
        key = (row["path"], tuple(row["dimensions"]))
        cases[key][result["variant"]].append(row)

    groups = collections.defaultdict(list)
    details = []
    baseline = "production16" if "production16" in environment["variants"] else "fixed16"
    for key, modes in cases.items():
        medians = {}
        for variant, trials in modes.items():
            assert len(trials) == environment["repeats"], (key, variant, len(trials))
            assert len({json.dumps(r["result"]["rounds"], sort_keys=True) for r in trials}) == 1
            assert len({(r["truth"], r["result"]["body_sha256"], r["result"]["encodes"],
                         r["result"]["comparisons"], r["result"]["decodes"]) for r in trials}) == 1
            medians[variant] = dict(trials[0], elapsed_us=statistics.median(r["result"]["elapsed_us"] for r in trials))
        base = medians[baseline]
        for variant, row in medians.items():
            size = min(environment["sizes"], key=lambda mp: abs(mp - row["megapixels"]))
            groups[(size, variant)].append((base, row))
            result = row["result"]
            floor = row["target"] - row["allowed_error"]
            expanded = row["nested"][-1]["score"]
            new_miss = base["truth"] >= floor and row["truth"] < floor
            unstable = result["stop"] == "stable" and expanded < floor
            if new_miss or unstable:
                details.append((row, new_miss, unstable))

    print(path)
    print(f"{len(cases)} cases; {len(rows)-1} samples; {environment['repeats']} repeats; baseline={baseline}")
    print("MP variant n speedup compare_ratio decode_ratio bytes_ratio full_miss new_miss stable expanded_miss median_tiles score_med")
    for (size, variant), pairs in sorted(groups.items()):
        floors = [row["target"] - row["allowed_error"] for _, row in pairs]
        misses = sum(row["full_truth"] >= floor > row["truth"] for (_, row), floor in zip(pairs, floors))
        new_misses = sum(base["truth"] >= floor > row["truth"] for (base, row), floor in zip(pairs, floors))
        stable = sum(row["result"]["stop"] == "stable" for _, row in pairs)
        expanded_misses = sum(row["result"]["stop"] == "stable" and row["nested"][-1]["score"] < floor
                              for (_, row), floor in zip(pairs, floors))
        print(
            f"{size:g} {variant} {len(pairs)} "
            f"{geomean([b['elapsed_us']/r['elapsed_us'] for b,r in pairs]):.2f} "
            f"{geomean([r['result']['comparisons']/b['result']['comparisons'] for b,r in pairs]):.3f} "
            f"{geomean([r['result']['decodes']/b['result']['decodes'] for b,r in pairs]):.3f} "
            f"{geomean([r['result']['bytes']/b['result']['bytes'] for b,r in pairs]):.3f} "
            f"{misses} {new_misses} {stable} {expanded_misses} "
            f"{statistics.median(r['result']['tiles'] for _,r in pairs):g} "
            f"{statistics.median(r['truth'] for _,r in pairs):.2f}"
        )
    for row, new_miss, unstable in details:
        print("DETAIL", row["path"], f"{row['megapixels']:.3f}MP", row["result"]["variant"],
              f"new_miss={new_miss} expanded_miss={unstable}",
              f"truth={row['truth']:.3f} score={row['result']['score']:.3f}",
              f"expanded={row['nested'][-1]['score']:.3f}")


for input_path in sys.argv[1:]:
    summarize(input_path)

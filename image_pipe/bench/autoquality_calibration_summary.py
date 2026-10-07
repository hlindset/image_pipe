"""Validate and summarize the memoized accuracy experiment; no timing claims."""

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
    groups = collections.defaultdict(list)
    changes = []
    total_points = 0
    total_runs = 0
    for case in rows[1:]:
        assert case["kind"] == "case"
        points = {point["quality"]: point for point in case["points"]}
        total_points += len(points)
        total_runs += len(case["runs"])
        size = min(environment["sizes"], key=lambda mp: abs(mp - case["megapixels"]))
        for target in environment["targets"]:
            runs = [run for run in case["runs"] if run["target"] == target]
            base = next(run for run in runs if run["scorer"] == "full" and run["cap"] == 6)
            for run in runs:
                point = points[run["quality"]]
                for field in ("bytes", "body_sha256", "truth"):
                    assert run[field] == point[field], (case["path"], field)
                estimate = point["truth"] if run["scorer"] == "full" else point["p10"]
                assert abs(run["estimated_score"] - (estimate - run["offset"])) < 1e-9
                assert run["iterations"] == len(run["trace"])
                assert len(set(run["trace"])) == len(run["trace"])
                assert run["quality"] in run["trace"]
                key = (case["split"], size, target, run["scorer"], run["offset"], run["cap"])
                groups[key].append((base, run))
                if run["cap"] > 6:
                    initial = next(
                        other for other in runs
                        if other["scorer"] == run["scorer"]
                        and other["offset"] == run["offset"] and other["cap"] == 6
                    )
                    if initial["quality"] != run["quality"]:
                        changes.append((case, initial, run))

    print(path)
    print(f"{len(rows) - 1} cases; {total_points} measured qualities; {total_runs} searches")
    print("split MP target scorer offset cap n miss score_min/median/max bytes_ratio probes_mean/max")
    for key, pairs in sorted(groups.items()):
        scores = [run["truth"] for _, run in pairs]
        misses = sum(
            base["truth"] >= run["target"] - run.get("allowed_error", 0.5)
            and run["truth"] < run["target"] - run.get("allowed_error", 0.5)
            for base, run in pairs
        )
        byte_ratio = geomean([run["bytes"] / base["bytes"] for base, run in pairs])
        probes = [run["iterations"] for _, run in pairs]
        split, size, target, scorer, offset, cap = key
        print(
            f"{split} {size:g} {target:g} {scorer} {offset:g} {cap} {len(pairs)} {misses} "
            f"{min(scores):.2f}/{statistics.median(scores):.2f}/{max(scores):.2f} "
            f"{byte_ratio:.3f} {statistics.mean(probes):.2f}/{max(probes)}"
        )
    for case, initial, run in changes:
        print(
            "CAP_CHANGE", case["path"], f"{case['megapixels']:.3f}MP",
            run["scorer"], run["offset"], f"{initial['cap']}->{run['cap']}",
            f"q={initial['quality']}->{run['quality']}",
            f"truth={initial['truth']:.2f}->{run['truth']:.2f}",
            f"probes={initial['iterations']}->{run['iterations']}",
        )


for input_path in sys.argv[1:]:
    summarize(input_path)

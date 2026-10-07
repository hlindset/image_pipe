"""Validate trial evidence and report paired medians, counts and worst cases.

Usage: python3 bench/autoquality_research_summary.py [--labels LABELS.jsonl] RESULT.jsonl ...
Speedup >1 means faster; final delivered bytes and independent scores are used.
"""
import collections
import json
import math
import statistics
import sys


def geomean(values):
    return math.exp(statistics.mean(math.log(v) for v in values))


def label_key(row):
    return row["path"], tuple(row["dimensions"]), row["format"]


def load_labels(path):
    with open(path, encoding="utf-8") as source:
        labels = [row for line in source if (row := json.loads(line))["kind"] == "label"]
    frames = {(row["path"], tuple(row["dimensions"])): row for row in labels}
    costs = [statistics.median(row["feature_us"]) / 1000 for row in frames.values()]
    print("Feature frames:", len(frames), "median ms:", round(statistics.median(costs), 3),
          "range:", round(min(costs), 3), round(max(costs), 3),
          "classifier median ms:", round(statistics.median(row["class_us"] for row in frames.values()) / 1000, 3))
    return {label_key(row): row for row in labels}


def summarize(path, labels):
    with open(path, encoding="utf-8") as source:
        rows = [json.loads(line) for line in source]
    env = rows[0]
    samples = [r for r in rows if r["kind"] == "sample"]
    print(path, env["experiment"], len(samples), "samples")
    if env["experiment"] == "prediction" and labels:
        production = [row for row in samples if row["result"]["variant"] == "production"]
        for row in production:
            baseline = labels[label_key(row)]
            assert baseline["body"]["sha256"] == row["result"]["sha256"]
            assert baseline["meta"] == row["result"]["meta"]
            assert baseline["truth"] == row["truth"]
        print("Collected production parity:", len(production))
    if env["experiment"] == "localized":
        for r in samples:
            print(r["content"], r["placement"], r["format"], "q", r["meta"]["quality"],
                  "full/window/region", *(round(r[k], 2) for k in ("full_truth", "window_truth", "region_truth")),
                  "estimate", round(r["meta"]["score"], 2))
        return

    if env["experiment"] == "jpeg_probes":
        for r in rows:
            if r["kind"] == "pixel_check":
                assert r["exact_pixel_equivalence"]
                assert r["final"]["default"]["identical_trial_body"]
            if r["kind"] == "budget_check":
                assert r["exact_final_body_equivalence"]
                assert r["normal"]["sha256"] == r["checked"]["sha256"]
                assert r["checked"]["bytes"] <= r["budget"] or r["checked"]["meta"]["limiting_factor"] == "max_bytes"
        print("Pixel checks:", sum(r["kind"] == "pixel_check" for r in rows), "budget checks:", sum(r["kind"] == "budget_check" for r in rows))

    cases = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in samples:
        result = r["result"]
        assert result["meta"]["iterations"] <= 6
        assert result["metric_calls"] <= result["meta"]["iterations"]
        key = (r.get("format", "jpeg"), r["path"], tuple(r["dimensions"]))
        mode = (result["packaging"], result["mode"]) if env["experiment"] == "jpeg_probes" else result["variant"]
        cases[key][mode].append(r)
    comparisons = collections.defaultdict(list)
    for key, variants in cases.items():
        medians = {}
        for mode, trials in variants.items():
            assert len(trials) == env["repeats"], (key, mode, len(trials))
            assert len({(r["truth"], r["result"]["sha256"], r["result"]["meta"]["quality"], r["result"]["encodes"], r["result"]["metric_calls"]) for r in trials}) == 1
            medians[mode] = (statistics.median(r["result"]["elapsed_us"] for r in trials), trials[0])
        for mode, (elapsed, row) in medians.items():
            baseline_mode = (mode[0], "normal") if env["experiment"] == "jpeg_probes" else "production"
            base_elapsed, base = medians[baseline_mode]
            if env["experiment"] == "jpeg_probes":
                assert base["result"]["sha256"] == row["result"]["sha256"]
                assert base["truth"] == row["truth"]
            comparisons[(key[0], str(mode))].append((base_elapsed / elapsed, base, row))
    for (codec, mode), pairs in sorted(comparisons.items()):
        speedups = [p[0] for p in pairs]
        misses = [(r["path"], r["megapixels"], r["truth"]) for _, _, r in pairs if r["truth"] < 74.5]
        new_misses = [(r["path"], r["megapixels"], r["truth"]) for _, b, r in pairs if b["truth"] >= 74.5 > r["truth"]]
        byte_ratio = geomean([r["result"]["bytes"] / b["result"]["bytes"] for _, b, r in pairs])
        encodes = statistics.mean(r["result"]["encodes"] for _, _, r in pairs)
        metric_calls = statistics.mean(r["result"]["metric_calls"] for _, _, r in pairs)
        worst = min(pairs, key=lambda p: p[0])
        print(codec, mode, "cases", len(pairs), "speedup", round(geomean(speedups), 3),
              "range", round(min(speedups), 3), round(max(speedups), 3), "bytes_ratio", round(byte_ratio, 4),
              "mean_encodes/metrics", round(encodes, 2), round(metric_calls, 2), "misses/new", len(misses), len(new_misses),
              "max_shortfall", round(max([74.5 - r[2] for r in misses] or [0]), 3),
              "worst_case", worst[2]["path"], round(worst[2]["megapixels"], 3))
        for row in new_misses:
            print("NEW_MISS", *row)


arguments = sys.argv[1:]
labels = {}
if arguments[:1] == ["--labels"]:
    labels = load_labels(arguments[1])
    arguments = arguments[2:]
for input_path in arguments:
    summarize(input_path, labels)

"""Fit fixed-penalty lightweight priors using training originals only.

Usage: python3 bench/autoquality_prediction_model.py labels.jsonl models.json
No external Python dependencies; ridge fitting weights originals equally.
The class lookup uses medians of training cases.
Labels are current search winners, not exhaustive minimum-passing qualities.
"""
import collections
import json
import math
import statistics
import sys


def solve(matrix, values):
    augmented = [row[:] + [value] for row, value in zip(matrix, values)]
    n = len(values)
    for column in range(n):
        pivot = max(range(column, n), key=lambda r: abs(augmented[r][column]))
        augmented[column], augmented[pivot] = augmented[pivot], augmented[column]
        divisor = augmented[column][column]
        assert abs(divisor) > 1e-12
        augmented[column] = [x / divisor for x in augmented[column]]
        for r in range(n):
            if r != column:
                factor = augmented[r][column]
                augmented[r] = [a - factor * b for a, b in zip(augmented[r], augmented[column])]
    return [row[-1] for row in augmented]


def fit(rows):
    counts = collections.Counter(r["path"] for r in rows)
    weights = [1 / counts[r["path"]] for r in rows]
    total = sum(weights)
    d = len(rows[0]["features"])
    mean = [sum(w * r["features"][j] for w, r in zip(weights, rows)) / total for j in range(d)]
    scale = [max(1e-6, math.sqrt(sum(w * (r["features"][j] - mean[j]) ** 2 for w, r in zip(weights, rows)) / total)) for j in range(d)]
    x = [[1.0] + [(v - m) / s for v, m, s in zip(r["features"], mean, scale)] for r in rows]
    y = [r["meta"]["quality"] for r in rows]
    # Penalty fixed before inspecting held-out outcomes; intercept unpenalized.
    penalty = 4.0
    matrix = [[sum(w * row[a] * row[b] for w, row in zip(weights, x)) + (penalty if a == b and a > 0 else 0) for b in range(d + 1)] for a in range(d + 1)]
    values = [sum(w * row[a] * target for w, row, target in zip(weights, x, y)) for a in range(d + 1)]
    coefficients = solve(matrix, values)
    lookup = {}
    for label in ("photo", "graphic"):
        group = [r["meta"]["quality"] for r in rows if r["class"] == label]
        lookup[label] = statistics.median(group or y)
    return {"mean": mean, "scale": scale, "intercept": coefficients[0], "coefficients": coefficients[1:],
            "penalty": penalty, "class_lookup": lookup, "training_images": sorted(counts), "training_cases": len(rows)}


with open(sys.argv[1], encoding="utf-8") as source:
    all_rows = [json.loads(line) for line in source]
labels = [r for r in all_rows if r["kind"] == "label"]
training = [r for r in labels if r["split"] == "exploratory"]
heldout = [r for r in labels if r["split"] == "validation"]
assert set(r["path"] for r in training).isdisjoint(r["path"] for r in heldout)
models = {format_: fit([r for r in training if r["format"] == format_]) for format_ in ("jpeg", "webp", "avif")}
result = {"models": models, "training_images": sorted(set(r["path"] for r in training)),
          "heldout_images": sorted(set(r["path"] for r in heldout)), "label": "production_search_winner",
          "environment": all_rows[0]}
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(result, output, indent=2, sort_keys=True)
    output.write("\n")
print(f"Fit three models on {len(result['training_images'])} originals; {len(result['heldout_images'])} held-out originals excluded from fitting.")

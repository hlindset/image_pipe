"""Run from the repo root:
mise exec -- python3 bench/materialization_latency.py /tmp/fd8-speed --preload

Fresh VMs, alternating order, request-only timings, exact pixel verification.
Compare the restored implementation, pre-fd8 behavior, and rejected lazy orientation.
Runtime overrides do not change source or beam files.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import statistics
import subprocess


def replace_once(source, before, after):
    assert source.count(before) == 1, before
    return source.replace(before, after, 1)


def overrides(root):
    orientation = Path("lib/image_pipe/transform/orientation_flush.ex").read_text()
    lazy = replace_once(
        orientation,
        "alias ImagePipe.Transform.{PendingOrientation, State}\n"
        "  alias Vix.Vips.Image, as: VipsImage",
        "alias ImagePipe.Transform.{Materializer, PendingOrientation, State}",
    )
    start = lazy.index("  @spec flush")
    end = lazy.index("  defp apply_orientation")
    lazy = lazy[:start] + '''  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    with {:ok, %State{} = state} <- prepare_random_access(state, po),
         {:ok, image} <- apply_orientation(state.image, po) do
      {:ok, %State{state | image: image, pending_orientation: nil}}
    end
  end

  defp prepare_random_access(%State{materialized?: true} = state, _pending), do: {:ok, state}

  defp prepare_random_access(state, %PendingOrientation{
         exif_angle: 0, user_angle: 0, user_flip_y: false
       }), do: {:ok, state}

  defp prepare_random_access(state, %PendingOrientation{}), do: Materializer.materialize(state)

''' + lazy[end:]
    flush = Path("lib/image_pipe/transform/operation/flush.ex").read_text()
    flush = replace_once(flush, "alias ImagePipe.Transform.Materializer",
                         "alias ImagePipe.Transform.OrientationFlush")
    flush = replace_once(flush, "    Materializer.flush(state)", '''    case OrientationFlush.flush(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:materialize_error, reason}}
    end''')
    color = Path("lib/image_pipe/transform/input_color_management.ex").read_text()
    start = color.index("  defp remove_profile(image)")
    end = color.index("  defp profile_data(image)")
    color = color[:start] + '''  defp remove_profile(image) do
    VixImage.mutate(image, fn mutable ->
      _ = MutableImage.remove(mutable, "icc-profile-data")
      :ok
    end)
  end

''' + color[end:]
    # Restored orientation has the historical buffering behavior; the ICC guard
    # is its only remaining performance change relative to the original baseline.
    variants = {
        "baseline": color,
        "lazy": lazy + flush,
    }
    for mode, source in variants.items():
        (root / f"{mode}.ex").write_text(source)


def mix(args):
    result = subprocess.run(["mix", "run", "--no-compile", *args],
                            text=True, capture_output=True, check=True)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--skip-prepare", action="store_true")
    parser.add_argument("--preload", action="store_true",
                        help="Load application/dependency modules before measuring the request")
    parser.add_argument("--case", action="append", dest="cases")
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    bench = "bench/pre_clamp_materialization.exs"
    if not args.skip_prepare:
        mix([bench, "audit", str(root)])
        shutil.copyfile("priv/static/images/beach.jpg", root / "jpeg.jpg")
    overrides(root)
    if args.preload:
        (root / "preload.exs").write_text('''
for {app, _, _} <- Application.loaded_applications(),
    module <- Application.spec(app, :modules) || [],
    do: Code.ensure_loaded(module)
''')
    cases = [
        ("plain", "fit", "plain", 3000, 1024),
        ("exif_large", "fit", "exif6", 6000, 2048),
        ("exif_small", "fit", "exif6", 128, 2048),
        ("rotate_jpeg", "rotated_fit", "jpeg", 2800, 2048),
        ("horizontal_large", "horizontal", "plain", 3000, 1024),
        ("horizontal_small", "horizontal", "jpeg", 128, 2048),
        ("rotation_groups", "rotation_groups", "plain", 3000, 1024),
        ("groups", "groups", "exif6", 6000, 2048),
        ("icc_absent", "fit", "scrgb_unprofiled", 128, 128),
        ("icc_present", "fit", "scrgb", 128, 128),
    ]
    rows = []
    for name, scenario, source, target, cap in cases:
        if args.cases and name not in args.cases:
            continue
        for trial in range(args.trials):
            modes = ["baseline", "current", "lazy"]
            if trial % 2:
                modes.reverse()
            for mode in modes:
                options = [] if mode == "current" else ["-r", str(root / f"{mode}.ex")]
                if args.preload:
                    options = [*options, "-r", str(root / "preload.exs")]
                output = mix([*options, bench, "worker", str(root), scenario,
                              source, str(target), str(cap)])
                row = json.loads(output.strip().splitlines()[-1])
                row.update(case=name, mode=mode, trial=trial + 1)
                rows.append(row)
                (root / "latency-results.json").write_text(json.dumps(rows, indent=2))
                print(f"{name} {trial + 1} {mode}: {row['elapsed_ms']:.1f} ms", flush=True)
        selected = [row for row in rows if row["case"] == name]
        assert len({(tuple(r["dimensions"]), r["pixel_sha256"]) for r in selected}) == 1, name
    write_results(root, rows, args.preload, args.trials)


def write_results(root, rows, preload, trials):
    summary = []
    for name in dict.fromkeys(row["case"] for row in rows):
        for mode in dict.fromkeys(row["mode"] for row in rows if row["case"] == name):
            selected = [r for r in rows if r["case"] == name and r["mode"] == mode]
            values = [r["elapsed_ms"] for r in selected]
            summary.append(dict(case=name, mode=mode, median_ms=statistics.median(values),
                                min_ms=min(values), max_ms=max(values),
                                median_peak_mib=statistics.median(
                                    r["libvips_peak_bytes"] / 2**20 for r in selected)))
    (root / "latency-summary.json").write_text(json.dumps(summary, indent=2))
    samples = []
    for item in summary:
        selected = [r for r in rows if r["case"] == item["case"] and r["mode"] == item["mode"]]
        samples.append({
            **item,
            "path": selected[0]["path"],
            "dimensions": selected[0]["dimensions"],
            "pixel_sha256": selected[0]["pixel_sha256"],
            "elapsed_ms": [r["elapsed_ms"] for r in selected],
            "peak_bytes": [r["libvips_peak_bytes"] for r in selected],
        })
    source_paths = [
        "bench/pre_clamp_materialization.exs",
        "lib/image_pipe/transform/orientation_flush.ex",
        "lib/image_pipe/transform/materializer.ex",
        "lib/image_pipe/transform/operation/flush.ex",
        "lib/image_pipe/transform/input_color_management.ex",
    ]
    evidence = {
        "preloaded_modules": preload,
        "trials_per_version": trials,
        "platform": platform.platform(),
        "libvips": rows[0]["vips"],
        "source_sha256": {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in source_paths},
        "samples": samples,
    }
    (root / "latency-samples.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

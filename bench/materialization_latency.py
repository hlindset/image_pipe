"""Run from the repo root:
mise exec -- python3 bench/materialization_latency.py /tmp/fd8-speed --preload

Fresh VMs, alternating order, request-only timings, exact pixel verification.
Runtime overrides restore pre-fd8 behavior without changing source or beam files.
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
    old = replace_once(
        orientation,
        "alias ImagePipe.Transform.{Materializer, PendingOrientation, State}",
        "alias ImagePipe.Transform.{PendingOrientation, State}\n"
        "  alias Vix.Vips.Image, as: VipsImage",
    )
    start = old.index("  @spec flush")
    end = old.index("  defp apply_orientation")
    old = old[:start] + '''  def flush(%State{pending_orientation: nil} = state), do: materialize(state)

  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    with {:ok, image} <- prepare_random_access(state.image, po),
         {:ok, image} <- apply_orientation(image, po),
         {:ok, image} <- VipsImage.copy_memory(image) do
      {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
    end
  end

  defp prepare_random_access(image, %PendingOrientation{} = po) do
    if po.exif_angle != 0 or po.user_angle != 0 or po.user_flip_y,
      do: VipsImage.copy_memory(image), else: {:ok, image}
  end

  defp materialize(%State{image: image} = state) do
    case VipsImage.copy_memory(image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end

''' + old[end:]
    materializer = Path("lib/image_pipe/transform/materializer.ex").read_text()
    materializer = replace_once(
        materializer, "  alias ImagePipe.Transform.State",
        "  alias ImagePipe.Transform.{OrientationFlush, State}",
    )
    position = materializer.rindex("\nend")
    materializer = materializer[:position] + '''
  def flush(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case OrientationFlush.flush(state) do
        {:ok, new_state} -> {{:ok, new_state}, ok_metadata(new_state)}
        {:error, reason} ->
          {{:error, {:materialize_error, reason}}, %{result: :materialize_error}}
      end
    end)
  end
''' + materializer[position:]
    flush = Path("lib/image_pipe/transform/operation/flush.ex").read_text()
    flush = replace_once(flush, "alias ImagePipe.Transform.OrientationFlush",
                         "alias ImagePipe.Transform.Materializer")
    flush = replace_once(flush, '''    case OrientationFlush.flush(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, {:materialize_error, reason}}
    end''', "    Materializer.flush(state)")
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
    # Restore only the final copy, keeping current preparation and telemetry.
    eager = replace_once(
        orientation,
        "{:ok, image} <- apply_orientation(state.image, po) do",
        "{:ok, image} <- apply_orientation(state.image, po),\n"
        "         {:ok, image} <- Vix.Vips.Image.copy_memory(image) do",
    )
    eager = replace_once(eager, "image: image, pending_orientation: nil",
                         "image: image, materialized?: true, pending_orientation: nil")
    reuse = replace_once(
        orientation,
        "  defp prepare_random_access(%State{materialized?: true} = state, _pending), do: {:ok, state}\n",
        "",
    )
    variants = {
        "baseline": old + materializer + flush + color,
        "eager_final": eager,
        "no_reuse": reuse,
        "icc_mutation": color,
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
        ("plain", "fit", "plain", 3000, 1024, "eager_final"),
        ("exif_large", "fit", "exif6", 6000, 2048, "eager_final"),
        ("exif_small", "fit", "exif6", 128, 2048, "eager_final"),
        ("rotate_jpeg", "rotated_fit", "jpeg", 2800, 2048, "eager_final"),
        ("horizontal_large", "horizontal", "plain", 3000, 1024, "eager_final"),
        ("horizontal_small", "horizontal", "jpeg", 128, 2048, "eager_final"),
        ("rotation_groups", "rotation_groups", "plain", 3000, 1024, "no_reuse"),
        ("groups", "groups", "exif6", 6000, 2048, "no_reuse"),
        ("icc_absent", "fit", "scrgb_unprofiled", 128, 128, "icc_mutation"),
        ("icc_present", "fit", "scrgb", 128, 128, "icc_mutation"),
    ]
    rows = []
    for name, scenario, source, target, cap, ablation in cases:
        if args.cases and name not in args.cases:
            continue
        for trial in range(args.trials):
            modes = ["baseline", "current", ablation]
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

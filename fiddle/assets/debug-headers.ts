// Pure rendering helper for the fiddle's debug panel. Turns the raw X-ImagePipe-*
// + Server-Timing header record (read by the service worker) plus the fetched body
// length into ordered display groups. The header surface and units mirror
// ImagePipe.Debug.Headers exactly (Server-Timing in milliseconds; no output-size
// header by design — the browser supplies the body length, from which we derive
// the compression ratio).

export type DebugRow = { label: string; value: string };
export type DebugGroup = { title: string; rows: DebugRow[] };

type Raw = Record<string, string> | null;

export function parseDebugHeaders(raw: Raw, outputBytes: number | null): DebugGroup[] | null {
  if (raw === null || Object.keys(raw).length === 0) return null;

  const get = (name: string): string | undefined => raw[name];
  const groups: DebugGroup[] = [];

  pushGroup(groups, "Source", [
    row("Format", get("x-imagepipe-source-format")),
    row("Size", formatBytes(toNumber(get("x-imagepipe-source-size")))),
    dimensionsRow(get("x-imagepipe-source-width"), get("x-imagepipe-source-height")),
    row("Color space", get("x-imagepipe-source-color-space")),
    boolRow("ICC profile", get("x-imagepipe-source-icc")),
    row("Bit depth", get("x-imagepipe-source-bit-depth")),
    boolRow("Alpha", get("x-imagepipe-source-alpha")),
    row("Orientation", get("x-imagepipe-source-orientation")),
    row("Shrink", get("x-imagepipe-shrink")),
  ]);

  const sourceBytes = toNumber(get("x-imagepipe-source-size"));
  pushGroup(groups, "Output", [
    row("Format", get("x-imagepipe-output-format")),
    boolRow("Negotiated", get("x-imagepipe-output-negotiated")),
    dimensionsRow(get("x-imagepipe-output-width"), get("x-imagepipe-output-height")),
    row("Quality", get("x-imagepipe-output-quality")),
    boolRow("Stripped", get("x-imagepipe-output-stripped")),
    row("Color profile", get("x-imagepipe-output-color-profile")),
    row("Distance", get("x-imagepipe-output-distance")),
    row("Accept", get("x-imagepipe-output-accept")),
    row("Output size", formatBytes(outputBytes)),
    row("Compression", compressionRatio(sourceBytes, outputBytes)),
  ]);

  pushGroup(groups, "Autoquality", [
    row("Metric", get("x-imagepipe-aq-metric")),
    row("Score", get("x-imagepipe-aq-score")),
    row("Target", get("x-imagepipe-aq-target")),
    row("Quality min", get("x-imagepipe-aq-quality-min")),
    row("Quality max", get("x-imagepipe-aq-quality-max")),
    row("Iterations", get("x-imagepipe-aq-iterations")),
    row("Outcome", get("x-imagepipe-aq-outcome")),
    row("Limiting factor", get("x-imagepipe-aq-limiting-factor")),
    row("Scorer", get("x-imagepipe-aq-scorer")),
    row("Tiles", get("x-imagepipe-aq-tiles")),
  ]);

  pushGroup(groups, "Cache", [
    row("Status", get("x-imagepipe-cache")),
    row("Key", get("x-imagepipe-cache-key")),
  ]);

  pushGroup(groups, "Pipeline", [row("Operations", get("x-imagepipe-pipeline"))]);

  pushGroup(groups, "Timing", parseServerTiming(get("server-timing")));

  return groups.length > 0 ? groups : null;
}

function pushGroup(groups: DebugGroup[], title: string, rows: (DebugRow | null)[]): void {
  const present = rows.filter((r): r is DebugRow => r !== null);
  if (present.length > 0) groups.push({ title, rows: present });
}

function row(label: string, value: string | undefined): DebugRow | null {
  return value === undefined || value === "" ? null : { label, value };
}

function boolRow(label: string, value: string | undefined): DebugRow | null {
  if (value === undefined) return null;
  return { label, value: value === "true" ? "yes" : value === "false" ? "no" : value };
}

function dimensionsRow(w: string | undefined, h: string | undefined): DebugRow | null {
  return w !== undefined && h !== undefined ? { label: "Dimensions", value: `${w} × ${h}` } : null;
}

function compressionRatio(
  sourceBytes: number | null,
  outputBytes: number | null,
): string | undefined {
  if (sourceBytes === null || outputBytes === null || outputBytes <= 0) return undefined;
  return `${(sourceBytes / outputBytes).toFixed(1)}×`;
}

function parseServerTiming(value: string | undefined): (DebugRow | null)[] {
  if (value === undefined) return [];
  return value.split(",").map((entry) => {
    const name = entry.split(";")[0]?.trim() ?? "";
    const dur = /dur=([\d.]+)/.exec(entry)?.[1];
    if (name === "" || dur === undefined) return null;
    return { label: capitalize(name), value: `${dur} ms` };
  });
}

function toNumber(value: string | undefined): number | null {
  if (value === undefined) return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function formatBytes(bytes: number | null): string | undefined {
  if (bytes === null) return undefined;
  return bytes < 1024 ? `${bytes} B` : `${(bytes / 1024).toFixed(1)} kB`;
}

function capitalize(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

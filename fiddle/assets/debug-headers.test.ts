import { describe, expect, it } from "vitest";

import { parseDebugHeaders, type DebugGroup } from "./debug-headers";

function group(groups: DebugGroup[] | null, title: string): DebugGroup | undefined {
  return groups?.find((g) => g.title === title);
}

describe("parseDebugHeaders", () => {
  it("returns null when there are no debug headers", () => {
    expect(parseDebugHeaders(null, 40000)).toBeNull();
    expect(parseDebugHeaders({}, 40000)).toBeNull();
  });

  it("groups source / output rows and derives output size + compression ratio", () => {
    const groups = parseDebugHeaders(
      {
        "x-imagepipe-source-format": "jpeg",
        "x-imagepipe-source-size": "184320",
        "x-imagepipe-source-width": "4000",
        "x-imagepipe-source-height": "3000",
        "x-imagepipe-source-icc": "true",
        "x-imagepipe-source-alpha": "false",
        "x-imagepipe-output-format": "avif",
        "x-imagepipe-output-negotiated": "true",
        "x-imagepipe-output-width": "1200",
        "x-imagepipe-output-height": "900",
        "x-imagepipe-output-quality": "72",
      },
      40000,
    );

    const source = group(groups, "Source");
    expect(source?.rows).toContainEqual({ label: "Format", value: "jpeg" });
    expect(source?.rows).toContainEqual({ label: "Size", value: "180.0 kB" });
    expect(source?.rows).toContainEqual({ label: "Dimensions", value: "4000 × 3000" });
    expect(source?.rows).toContainEqual({ label: "ICC profile", value: "yes" });
    expect(source?.rows).toContainEqual({ label: "Alpha", value: "no" });

    const output = group(groups, "Output");
    expect(output?.rows).toContainEqual({ label: "Format", value: "avif" });
    expect(output?.rows).toContainEqual({ label: "Negotiated", value: "yes" });
    expect(output?.rows).toContainEqual({ label: "Dimensions", value: "1200 × 900" });
    expect(output?.rows).toContainEqual({ label: "Quality", value: "72" });
    expect(output?.rows).toContainEqual({ label: "Output size", value: "39.1 kB" });
    expect(output?.rows).toContainEqual({ label: "Compression", value: "4.6×" });
  });

  it("renders the 'default' quality sentinel verbatim", () => {
    const groups = parseDebugHeaders({ "x-imagepipe-output-quality": "default" }, null);
    expect(group(groups, "Output")?.rows).toContainEqual({ label: "Quality", value: "default" });
  });

  it("emits the autoquality group only when AQ headers are present", () => {
    const none = parseDebugHeaders({ "x-imagepipe-output-format": "avif" }, null);
    expect(group(none, "Autoquality")).toBeUndefined();

    const groups = parseDebugHeaders(
      {
        "x-imagepipe-aq-metric": "ssimulacra2",
        "x-imagepipe-aq-score": "78.4",
        "x-imagepipe-aq-target": "78.0",
        "x-imagepipe-aq-quality-min": "60",
        "x-imagepipe-aq-quality-max": "65",
        "x-imagepipe-aq-outcome": "hit",
        "x-imagepipe-aq-scorer": "crop",
        "x-imagepipe-aq-tiles": "9",
      },
      null,
    );
    const aq = group(groups, "Autoquality");
    expect(aq?.rows).toContainEqual({ label: "Metric", value: "ssimulacra2" });
    expect(aq?.rows).toContainEqual({ label: "Score", value: "78.4" });
    expect(aq?.rows).toContainEqual({ label: "Quality min", value: "60" });
    expect(aq?.rows).toContainEqual({ label: "Tiles", value: "9" });
  });

  it("renders cache status + key and the pipeline list", () => {
    const groups = parseDebugHeaders(
      {
        "x-imagepipe-cache": "hit",
        "x-imagepipe-cache-key": "a1b2c3",
        "x-imagepipe-pipeline": "scale,crop,sharpen",
      },
      null,
    );
    expect(group(groups, "Cache")?.rows).toContainEqual({ label: "Status", value: "hit" });
    expect(group(groups, "Cache")?.rows).toContainEqual({ label: "Key", value: "a1b2c3" });
    expect(group(groups, "Pipeline")?.rows).toContainEqual({
      label: "Operations",
      value: "scale,crop,sharpen",
    });
  });

  it("parses Server-Timing into per-stage millisecond rows", () => {
    const groups = parseDebugHeaders(
      { "server-timing": "decode;dur=8.1, transform;dur=21, encode;dur=140, cache;dur=1.5, total;dur=181" },
      null,
    );
    const timing = group(groups, "Timing");
    expect(timing?.rows).toContainEqual({ label: "Decode", value: "8.1 ms" });
    expect(timing?.rows).toContainEqual({ label: "Cache", value: "1.5 ms" });
    expect(timing?.rows).toContainEqual({ label: "Total", value: "181 ms" });
  });
});

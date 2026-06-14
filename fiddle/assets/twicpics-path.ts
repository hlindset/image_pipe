import { sampleImages, type SourceImage } from "./processing-path";

export type TwicAnchor =
  | "top"
  | "bottom"
  | "left"
  | "right"
  | "top-left"
  | "top-right"
  | "bottom-left"
  | "bottom-right";

// 3x3 reading order (no center — center is the default focus, not an anchor literal).
export const twicAnchors: readonly TwicAnchor[] = [
  "top-left",
  "top",
  "top-right",
  "left",
  "right",
  "bottom-left",
  "bottom",
  "bottom-right",
];

// A resize dimension. unit "auto" emits "-" and ignores value (normalized to 0).
export type TwicResizeUnit = "px" | "p" | "s" | "auto";
export type TwicDim = { unit: TwicResizeUnit; value: number };

export type TransformStep =
  | { type: "resize"; id: string; w: TwicDim; h: TwicDim }
  | { type: "cover"; id: string; mode: "size" | "ratio"; w: number; h: number }
  | { type: "contain"; id: string; w: number; h: number }
  | { type: "inside"; id: string; w: number; h: number }
  | { type: "crop"; id: string; w: number; h: number; origin: { x: number; y: number } | null }
  | { type: "focus"; id: string; anchor: TwicAnchor };

export type TransformType = TransformStep["type"];

export type TwicOutput = "auto" | "avif" | "webp" | "jpeg" | "png";
export const twicOutputs: readonly TwicOutput[] = ["auto", "avif", "webp", "jpeg", "png"];

export type TwicPicsState = {
  source: SourceImage;
  chain: TransformStep[];
  output: TwicOutput;
  quality: number;
};

export const defaultTwicPicsState: TwicPicsState = {
  source: "images/dog.jpg",
  chain: [],
  output: "auto",
  quality: 80,
};

const sourceSet = new Set<string>(sampleImages.map((image) => image.path));

export function sourceForTwicPath(path: string): SourceImage | null {
  return sourceSet.has(path) ? (path as SourceImage) : null;
}

// Session-local monotonic id generator. Ids are never serialized into the URL —
// they only key the sortable list across reorders. Both the "+ Add" menu and
// parseTwicTail draw from this single counter, so ids never collide.
let idCounter = 0;
export function nextStepId(): string {
  idCounter += 1;
  return `t${idCounter}`;
}

export function defaultStep(type: TransformType, id: string): TransformStep {
  switch (type) {
    case "resize":
      return { type: "resize", id, w: { unit: "px", value: 300 }, h: { unit: "auto", value: 0 } };
    case "cover":
      return { type: "cover", id, mode: "size", w: 200, h: 200 };
    case "contain":
      return { type: "contain", id, w: 300, h: 300 };
    case "inside":
      return { type: "inside", id, w: 300, h: 300 };
    case "crop":
      return { type: "crop", id, w: 200, h: 200, origin: null };
    case "focus":
      return { type: "focus", id, anchor: "top" };
  }
}

// Editing helper for the resize axes. Setting one axis to "auto" while the other
// is already auto would serialize a degenerate `resize=-` that the parser rejects
// (and that parseTwicTail itself refuses to round-trip), so this keeps at least
// one concrete axis.
export function setResizeAxisUnit(
  step: Extract<TransformStep, { type: "resize" }>,
  axis: "w" | "h",
  unit: TwicResizeUnit,
): void {
  if (unit === "auto") {
    step[axis] = { unit: "auto", value: 0 };
    const other = axis === "w" ? "h" : "w";
    if (step[other].unit === "auto") {
      step[other] = { unit: "px", value: 300 };
    }
    return;
  }

  const prev = step[axis].value;
  step[axis] = { unit, value: prev > 0 ? prev : unit === "s" ? 1 : unit === "p" ? 100 : 300 };
}

// --- encoding ---

function encodeDim(dim: TwicDim): string {
  switch (dim.unit) {
    case "auto":
      return "-";
    case "px":
      return `${dim.value}`;
    case "p":
      return `${dim.value}p`;
    case "s":
      return `${dim.value}s`;
  }
}

export function stepToken(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return step.h.unit === "auto"
        ? `resize=${encodeDim(step.w)}`
        : `resize=${encodeDim(step.w)}x${encodeDim(step.h)}`;
    case "cover":
      return step.mode === "ratio" ? `cover=${step.w}:${step.h}` : `cover=${step.w}x${step.h}`;
    case "contain":
      return `contain=${step.w}x${step.h}`;
    case "inside":
      return `inside=${step.w}x${step.h}`;
    case "crop":
      return step.origin === null
        ? `crop=${step.w}x${step.h}`
        : `crop=${step.w}x${step.h}@${step.origin.x}x${step.origin.y}`;
    case "focus":
      return `focus=${step.anchor}`;
  }
}

export function twicParam(state: TwicPicsState): string {
  const segments = [
    ...state.chain.map(stepToken),
    `output=${state.output}`,
    `quality=${state.quality}`,
  ];
  return `v1/${segments.join("/")}`;
}

export function twicFetchPath(state: TwicPicsState): string {
  return `/twic/${state.source}?twic=${twicParam(state)}`;
}

export function twicBrowserPath(state: TwicPicsState): string {
  return `/twicpics/${state.source}?twic=${twicParam(state)}`;
}

// --- summaries (display only; not part of the wire contract) ---

function dimLabel(dim: TwicDim): string {
  switch (dim.unit) {
    case "auto":
      return "auto";
    case "px":
      return `${dim.value}px`;
    case "p":
      return `${dim.value}%`;
    case "s":
      return `${dim.value}s`;
  }
}

export function stepSummary(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return `${dimLabel(step.w)} × ${dimLabel(step.h)}`;
    case "cover":
      return step.mode === "ratio" ? `${step.w}:${step.h}` : `${step.w}×${step.h}`;
    case "contain":
    case "inside":
      return `${step.w}×${step.h}`;
    case "crop":
      return step.origin === null
        ? `${step.w}×${step.h}`
        : `${step.w}×${step.h} @ ${step.origin.x},${step.origin.y}`;
    case "focus":
      return step.anchor;
  }
}

// --- parsing (mirror lib/image_pipe/parser/twic_pics; pixel-only subset matching
// the UI surface — see the design spec) ---

const anchorSet = new Set<string>(twicAnchors);

function parsePositiveInt(value: string): number | null {
  return /^\d+$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parsePositiveNumber(value: string): number | null {
  return /^\d+(\.\d+)?$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parseResizeDim(token: string): TwicDim | null {
  if (token === "-") return { unit: "auto", value: 0 };
  if (token.endsWith("p")) {
    const n = parsePositiveNumber(token.slice(0, -1));
    return n === null ? null : { unit: "p", value: n };
  }
  if (token.endsWith("s")) {
    const n = parsePositiveNumber(token.slice(0, -1));
    return n === null ? null : { unit: "s", value: n };
  }
  const n = parsePositiveInt(token);
  return n === null ? null : { unit: "px", value: n };
}

function parsePxPair(args: string): { w: number; h: number } | null {
  const parts = args.split("x");
  if (parts.length !== 2) return null;
  const w = parsePositiveInt(parts[0]!);
  const h = parsePositiveInt(parts[1]!);
  return w === null || h === null ? null : { w, h };
}

function parseResize(args: string, id: string): TransformStep | null {
  if (args.includes(":")) return null; // ratio resize is rejected by the parser
  const parts = args.split("x");
  if (parts.length === 1) {
    const w = parseResizeDim(parts[0]!);
    if (w === null || w.unit === "auto") return null; // bare "-" / both-auto not emitted
    return { type: "resize", id, w, h: { unit: "auto", value: 0 } };
  }
  if (parts.length === 2) {
    const w = parseResizeDim(parts[0]!);
    const h = parseResizeDim(parts[1]!);
    if (w === null || h === null) return null;
    if (w.unit === "auto" && h.unit === "auto") return null;
    return { type: "resize", id, w, h };
  }
  return null;
}

function parseCover(args: string, id: string): TransformStep | null {
  if (args.includes(":")) {
    const parts = args.split(":");
    if (parts.length !== 2) return null;
    const w = parsePositiveNumber(parts[0]!);
    const h = parsePositiveNumber(parts[1]!);
    return w === null || h === null ? null : { type: "cover", id, mode: "ratio", w, h };
  }
  const pair = parsePxPair(args);
  return pair === null ? null : { type: "cover", id, mode: "size", w: pair.w, h: pair.h };
}

function parseCrop(args: string, id: string): TransformStep | null {
  const parts = args.split("@");
  if (parts.length > 2) return null;
  const size = parsePxPair(parts[0]!);
  if (size === null) return null;
  if (parts.length === 1) {
    return { type: "crop", id, w: size.w, h: size.h, origin: null };
  }
  const origin = parsePxPair(parts[1]!); // XxY
  return origin === null
    ? null
    : { type: "crop", id, w: size.w, h: size.h, origin: { x: origin.w, y: origin.h } };
}

function parseStep(name: string, args: string): TransformStep | null {
  const id = nextStepId();
  switch (name) {
    case "resize":
      return parseResize(args, id);
    case "cover":
      return parseCover(args, id);
    case "contain": {
      const pair = parsePxPair(args);
      return pair === null ? null : { type: "contain", id, w: pair.w, h: pair.h };
    }
    case "inside": {
      const pair = parsePxPair(args);
      return pair === null ? null : { type: "inside", id, w: pair.w, h: pair.h };
    }
    case "crop":
      return parseCrop(args, id);
    case "focus":
      return anchorSet.has(args) ? { type: "focus", id, anchor: args as TwicAnchor } : null;
    default:
      return null;
  }
}

export function parseTwicTail(sourceTail: string, search: string): TwicPicsState | null {
  const source = sourceForTwicPath(sourceTail);
  if (source === null) return null;

  const twic = new URLSearchParams(search).get("twic");
  if (twic === null || twic === "") {
    return { source, chain: [], output: "auto", quality: 80 };
  }

  if (twic !== "v1" && !twic.startsWith("v1/")) return null;
  const body = twic === "v1" ? "" : twic.slice("v1/".length);
  const segments = body.split("/").filter((segment) => segment !== "");

  const chain: TransformStep[] = [];
  let output: TwicOutput = "auto";
  let quality = 80;

  for (const segment of segments) {
    const eq = segment.indexOf("=");
    if (eq <= 0) return null; // every segment must be name=args

    const name = segment.slice(0, eq);
    const args = segment.slice(eq + 1);

    if (name === "output") {
      if (!twicOutputs.includes(args as TwicOutput)) return null;
      output = args as TwicOutput;
      continue;
    }
    if (name === "quality") {
      const q = parsePositiveInt(args);
      if (q === null || q > 100) return null;
      quality = q;
      continue;
    }

    const step = parseStep(name, args);
    if (step === null) return null;
    chain.push(step);
  }

  return { source, chain, output, quality };
}

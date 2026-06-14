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

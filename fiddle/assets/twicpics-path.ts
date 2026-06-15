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

// A TwicPics length with a unit suffix: px (bare number), p (percent), s (scale).
// Used by crop W/H (strictly > 0), crop origin coordinates (>= 0), and — without
// the "px" member — by relative coordinate focus (the parser rejects bare-pixel
// focus, so the UI must never emit it).
export type TwicLenUnit = "px" | "p" | "s";
export type TwicLen = { unit: TwicLenUnit; value: number };
// Coordinate focus accepts relative units only (p/s); a bare-pixel focus is
// parser-rejected.
export type TwicRelUnit = "p" | "s";
export type TwicRelLen = { unit: TwicRelUnit; value: number };

export type TwicCropOrigin = { x: TwicLen; y: TwicLen } | null;

// Cover (in size mode) and contain mirror the resize unit set exactly — the
// parser feeds both through `Units.size` with no `pixels_only` gate, so px / %
// / scale / auto all round-trip. They carry the same `TwicDim` shape as resize.
// Cover *ratio* mode keeps plain numbers (`W:H`). Inside mirrors cover's
// size/ratio split: size mode is pixels-only (the parser's
// `pixels_only([w,h], :inside)` gate rejects relative units), so it keeps plain
// `number` px dimensions; ratio mode pads/letterboxes to a plain `W:H` aspect
// ratio.
export type TransformStep =
  | { type: "resize"; id: string; w: TwicDim; h: TwicDim }
  | { type: "cover"; id: string; mode: "size"; w: TwicDim; h: TwicDim }
  | { type: "cover"; id: string; mode: "ratio"; w: number; h: number }
  | { type: "contain"; id: string; w: TwicDim; h: TwicDim }
  | { type: "inside"; id: string; mode: "size"; w: number; h: number }
  | { type: "inside"; id: string; mode: "ratio"; w: number; h: number }
  | { type: "crop"; id: string; w: TwicLen; h: TwicLen; origin: TwicCropOrigin }
  | { type: "focus"; id: string; mode: "anchor"; anchor: TwicAnchor }
  | { type: "focus"; id: string; mode: "coord"; x: TwicRelLen; y: TwicRelLen };

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
      return {
        type: "cover",
        id,
        mode: "size",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 200 },
      };
    case "contain":
      return {
        type: "contain",
        id,
        w: { unit: "px", value: 300 },
        h: { unit: "px", value: 300 },
      };
    case "inside":
      return { type: "inside", id, mode: "size", w: 300, h: 300 };
    case "crop":
      return {
        type: "crop",
        id,
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 200 },
        origin: null,
      };
    case "focus":
      return { type: "focus", id, mode: "anchor", anchor: "top" };
  }
}

// Editing helper for any two-axis dimension control (resize, cover-size, contain).
// Setting one axis to "auto" while the other is already auto would emit a
// degenerate both-auto token (`resize=-` / `cover=-` / `contain=-`) that is a
// no-op; this keeps at least one concrete axis as a UI round-trip guard.
export function setDimAxisUnit(
  step: { w: TwicDim; h: TwicDim },
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

// A unit-suffixed length (crop W/H, crop origin, relative focus): px is a bare
// number, p/s carry their suffix.
function encodeLen(len: TwicLen): string {
  switch (len.unit) {
    case "px":
      return `${len.value}`;
    case "p":
      return `${len.value}p`;
    case "s":
      return `${len.value}s`;
  }
}

// A two-axis dimension pair (resize, cover-size, contain): an auto height
// collapses to the single-axis `W` form (the omitted axis is implicit), matching
// what the parser's `Units.size` accepts.
function encodeDimPair(w: TwicDim, h: TwicDim): string {
  return h.unit === "auto" ? encodeDim(w) : `${encodeDim(w)}x${encodeDim(h)}`;
}

export function stepToken(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return `resize=${encodeDimPair(step.w, step.h)}`;
    case "cover":
      return step.mode === "ratio"
        ? `cover=${step.w}:${step.h}`
        : `cover=${encodeDimPair(step.w, step.h)}`;
    case "contain":
      return `contain=${encodeDimPair(step.w, step.h)}`;
    case "inside":
      return step.mode === "ratio" ? `inside=${step.w}:${step.h}` : `inside=${step.w}x${step.h}`;
    case "crop":
      return step.origin === null
        ? `crop=${encodeLen(step.w)}x${encodeLen(step.h)}`
        : `crop=${encodeLen(step.w)}x${encodeLen(step.h)}@${encodeLen(step.origin.x)}x${encodeLen(step.origin.y)}`;
    case "focus":
      return step.mode === "anchor"
        ? `focus=${step.anchor}`
        : `focus=${encodeLen(step.x)}x${encodeLen(step.y)}`;
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

function lenLabel(len: TwicLen): string {
  switch (len.unit) {
    case "px":
      return `${len.value}px`;
    case "p":
      return `${len.value}%`;
    case "s":
      return `${len.value}s`;
  }
}

export function stepSummary(step: TransformStep): string {
  switch (step.type) {
    case "resize":
      return `${dimLabel(step.w)} × ${dimLabel(step.h)}`;
    case "cover":
      return step.mode === "ratio"
        ? `${step.w}:${step.h}`
        : `${dimLabel(step.w)} × ${dimLabel(step.h)}`;
    case "contain":
      return `${dimLabel(step.w)} × ${dimLabel(step.h)}`;
    case "inside":
      return step.mode === "ratio" ? `${step.w}:${step.h}` : `${step.w}×${step.h}`;
    case "crop":
      return step.origin === null
        ? `${lenLabel(step.w)}×${lenLabel(step.h)}`
        : `${lenLabel(step.w)}×${lenLabel(step.h)} @ ${lenLabel(step.origin.x)},${lenLabel(step.origin.y)}`;
    case "focus":
      return step.mode === "anchor" ? step.anchor : `${lenLabel(step.x)},${lenLabel(step.y)}`;
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

// A two-axis dimension pair (resize, cover-size, contain): px / % / scale / auto
// per axis, single-axis `W` implies an auto height, both-auto is refused as a
// UI round-trip guard (avoids emitting the degenerate no-op `-` token). Ratio
// (`W:H`) is handled by the caller.
function parseDimPair(args: string): { w: TwicDim; h: TwicDim } | null {
  const parts = args.split("x");
  if (parts.length === 1) {
    const w = parseResizeDim(parts[0]!);
    if (w === null || w.unit === "auto") return null;
    return { w, h: { unit: "auto", value: 0 } };
  }
  if (parts.length === 2) {
    const w = parseResizeDim(parts[0]!);
    const h = parseResizeDim(parts[1]!);
    if (w === null || h === null) return null;
    if (w.unit === "auto" && h.unit === "auto") return null;
    return { w, h };
  }
  return null;
}

// A non-negative integer / number (for zero-based origin coordinates).
function parseNonNegativeInt(value: string): number | null {
  return /^\d+$/.test(value) ? Number(value) : null;
}

function parseNonNegativeNumber(value: string): number | null {
  return /^\d+(\.\d+)?$/.test(value) ? Number(value) : null;
}

// A unit-suffixed TwicPics length: px (bare integer), p (percent), s (scale).
// `allowZero` distinguishes crop size (strictly > 0) from origin coordinates (>= 0,
// so `@0x0` is the top-left).
function parseLen(token: string, allowZero: boolean): TwicLen | null {
  const num = allowZero ? parseNonNegativeNumber : parsePositiveNumber;
  const int = allowZero ? parseNonNegativeInt : parsePositiveInt;
  if (token.endsWith("p")) {
    const n = num(token.slice(0, -1));
    return n === null ? null : { unit: "p", value: n };
  }
  if (token.endsWith("s")) {
    const n = num(token.slice(0, -1));
    return n === null ? null : { unit: "s", value: n };
  }
  const n = int(token);
  return n === null ? null : { unit: "px", value: n };
}

function parseLenPair(args: string, allowZero: boolean): { x: TwicLen; y: TwicLen } | null {
  const parts = args.split("x");
  if (parts.length !== 2) return null;
  const x = parseLen(parts[0]!, allowZero);
  const y = parseLen(parts[1]!, allowZero);
  return x === null || y === null ? null : { x, y };
}

// A relative (p/s) focus coordinate. Bare-pixel focus is rejected by the parser,
// and the in-range guard mirrors the plan-builder's `focal_ratio` (ratio <= 1,
// i.e. <= 100% / <= 1s).
function parseRelLen(token: string): TwicRelLen | null {
  if (token.endsWith("p")) {
    const n = parseNonNegativeNumber(token.slice(0, -1));
    return n === null || n > 100 ? null : { unit: "p", value: n };
  }
  if (token.endsWith("s")) {
    const n = parseNonNegativeNumber(token.slice(0, -1));
    return n === null || n > 1 ? null : { unit: "s", value: n };
  }
  return null; // bare-pixel focus coordinates are not supported
}

function parseResize(args: string, id: string): TransformStep | null {
  if (args.includes(":")) return null; // ratio resize is rejected by the parser
  const pair = parseDimPair(args);
  return pair === null ? null : { type: "resize", id, w: pair.w, h: pair.h };
}

function parseCover(args: string, id: string): TransformStep | null {
  if (args.includes(":")) {
    const parts = args.split(":");
    if (parts.length !== 2) return null;
    const w = parsePositiveNumber(parts[0]!);
    const h = parsePositiveNumber(parts[1]!);
    return w === null || h === null ? null : { type: "cover", id, mode: "ratio", w, h };
  }
  const pair = parseDimPair(args);
  return pair === null ? null : { type: "cover", id, mode: "size", w: pair.w, h: pair.h };
}

// Inside mirrors cover's size/ratio split: a `W:H` arg is a ratio (plain
// positive numbers), otherwise a px `WxH` size pair. Size is pixels-only — the
// parser's `pixels_only([w,h], :inside)` gate rejects relative units, so the UI
// must never parse (or emit) a % / scale here.
function parseInside(args: string, id: string): TransformStep | null {
  if (args.includes(":")) {
    const parts = args.split(":");
    if (parts.length !== 2) return null;
    const w = parsePositiveNumber(parts[0]!);
    const h = parsePositiveNumber(parts[1]!);
    return w === null || h === null ? null : { type: "inside", id, mode: "ratio", w, h };
  }
  const pair = parsePxPair(args);
  return pair === null ? null : { type: "inside", id, mode: "size", w: pair.w, h: pair.h };
}

function parseCrop(args: string, id: string): TransformStep | null {
  const parts = args.split("@");
  if (parts.length > 2) return null;
  const size = parseLenPair(parts[0]!, false); // size: strictly > 0
  if (size === null) return null;
  if (parts.length === 1) {
    return { type: "crop", id, w: size.x, h: size.y, origin: null };
  }
  const origin = parseLenPair(parts[1]!, true); // origin: >= 0 (zero-based)
  return origin === null
    ? null
    : { type: "crop", id, w: size.x, h: size.y, origin: { x: origin.x, y: origin.y } };
}

function parseFocus(args: string, id: string): TransformStep | null {
  if (anchorSet.has(args)) {
    return { type: "focus", id, mode: "anchor", anchor: args as TwicAnchor };
  }
  const parts = args.split("x");
  if (parts.length !== 2) return null;
  const x = parseRelLen(parts[0]!);
  const y = parseRelLen(parts[1]!);
  return x === null || y === null ? null : { type: "focus", id, mode: "coord", x, y };
}

function parseStep(name: string, args: string): TransformStep | null {
  const id = nextStepId();
  switch (name) {
    case "resize":
      return parseResize(args, id);
    case "cover":
      return parseCover(args, id);
    case "contain": {
      const pair = parseDimPair(args);
      return pair === null ? null : { type: "contain", id, w: pair.w, h: pair.h };
    }
    case "inside":
      return parseInside(args, id);
    case "crop":
      return parseCrop(args, id);
    case "focus":
      return parseFocus(args, id);
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

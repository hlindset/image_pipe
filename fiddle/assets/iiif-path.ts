import { sampleImages, type SourceImage } from "./processing-path";

export type IiifRegion =
  | { kind: "full" }
  | { kind: "square" }
  | { kind: "px"; x: number; y: number; w: number; h: number } // ints; x,y>=0; w,h>=1
  | { kind: "pct"; x: number; y: number; w: number; h: number }; // decimals; x,y>=0; w,h>0

export type IiifSize =
  | { kind: "max" }
  | { kind: "w"; w: number } // w,    positive int
  | { kind: "h"; h: number } // ,h    positive int
  | { kind: "wh"; w: number; h: number } // w,h positive ints (may distort)
  | { kind: "confined"; w: number; h: number } // !w,h positive ints
  | { kind: "pct"; n: number }; // pct:n  >0; >100 only with upscale

export type IiifRotation = { degrees: number; mirror: boolean };
export type IiifQuality = "default" | "color" | "gray" | "bitonal";
export type IiifFormat = "jpg" | "png" | "webp" | "avif";

export type IiifState = {
  source: SourceImage;
  region: IiifRegion;
  size: IiifSize;
  upscale: boolean;
  rotation: IiifRotation;
  quality: IiifQuality;
  format: IiifFormat;
};

const iiifQualities: readonly IiifQuality[] = ["default", "color", "gray", "bitonal"];
const iiifFormats: readonly IiifFormat[] = ["jpg", "png", "webp", "avif"];

// images/dog.jpg -> "dog". Sample filenames are URL-safe (no spaces/% / #), so the
// path basename equals the real filename and matches the backend's Path.rootname —
// no decode/encode needed. (Keep sample images URL-safe by convention.)
export function iiifIdForSource(source: SourceImage): string {
  return source.replace(/^images\//, "").replace(/\.[^.]+$/, "");
}

const idToSource = new Map<string, SourceImage>(
  sampleImages.map((image) => [iiifIdForSource(image.path), image.path]),
);

export function sourceForIiifId(id: string): SourceImage | null {
  return idToSource.get(id) ?? null;
}

export const defaultIiifState: IiifState = {
  source: "images/dog.jpg",
  region: { kind: "full" },
  size: { kind: "max" },
  upscale: false,
  rotation: { degrees: 0, mirror: false },
  quality: "default",
  format: "jpg",
};

export type NumericLimit = { min: number; max: number; step: number };

// px region inputs clamp per-axis to the source's real dimensions (UX nicety; the
// backend clips partial out-of-bounds). Size dimensions are positive ints.
export const iiifControlLimits = {
  size: { min: 1, max: 8000, step: 1 },
  pct: { min: 1, max: 1000, step: 1 },
} satisfies { size: NumericLimit; pct: NumericLimit };

export function iiifRegionSegment(region: IiifRegion): string {
  switch (region.kind) {
    case "full":
      return "full";
    case "square":
      return "square";
    case "px":
      return `${region.x},${region.y},${region.w},${region.h}`;
    case "pct":
      return `pct:${region.x},${region.y},${region.w},${region.h}`;
  }
}

export function iiifSizeSegment(size: IiifSize, upscale: boolean): string {
  const prefix = upscale ? "^" : "";
  switch (size.kind) {
    case "max":
      return `${prefix}max`;
    case "w":
      return `${prefix}${size.w},`;
    case "h":
      return `${prefix},${size.h}`;
    case "wh":
      return `${prefix}${size.w},${size.h}`;
    case "confined":
      return `${prefix}!${size.w},${size.h}`;
    case "pct":
      return `${prefix}pct:${size.n}`;
  }
}

export function iiifPathTail(state: IiifState): string {
  const id = iiifIdForSource(state.source);
  const region = iiifRegionSegment(state.region);
  const size = iiifSizeSegment(state.size, state.upscale);
  const rotation = `${state.rotation.mirror ? "!" : ""}${state.rotation.degrees}`;
  return `${id}/${region}/${size}/${rotation}/${state.quality}.${state.format}`;
}

export function iiifBrowserPath(state: IiifState): string {
  return `/iiif/${iiifPathTail(state)}`;
}

export function iiifFetchPath(state: IiifState): string {
  return `/iiif-image/${iiifPathTail(state)}`;
}

// --- parsing (mirror lib/image_pipe/parser/iiif/grammar.ex) ---

function parsePositiveInt(value: string): number | null {
  return /^\d+$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parseNonNegInt(value: string): number | null {
  return /^\d+$/.test(value) ? Number(value) : null;
}

function parseDecimal(value: string): number | null {
  return /^\d+(\.\d+)?$/.test(value) ? Number(value) : null;
}

function parseRegion(token: string): IiifRegion | null {
  if (token === "full") return { kind: "full" };
  if (token === "square") return { kind: "square" };

  if (token.startsWith("pct:")) {
    const parts = token.slice(4).split(",");
    if (parts.length !== 4) return null;
    const x = parseDecimal(parts[0]!);
    const y = parseDecimal(parts[1]!);
    const w = parseDecimal(parts[2]!);
    const h = parseDecimal(parts[3]!);
    if (x === null || y === null || w === null || h === null) return null;
    if (w <= 0 || h <= 0) return null;
    return { kind: "pct", x, y, w, h };
  }

  const parts = token.split(",");
  if (parts.length !== 4) return null;
  const x = parseNonNegInt(parts[0]!);
  const y = parseNonNegInt(parts[1]!);
  const w = parsePositiveInt(parts[2]!);
  const h = parsePositiveInt(parts[3]!);
  if (x === null || y === null || w === null || h === null) return null;
  return { kind: "px", x, y, w, h };
}

function parseSize(rawToken: string): { size: IiifSize; upscale: boolean } | null {
  const upscale = rawToken.startsWith("^");
  const token = upscale ? rawToken.slice(1) : rawToken;

  if (token === "max") return { size: { kind: "max" }, upscale };

  if (token.startsWith("pct:")) {
    const n = parseDecimal(token.slice(4));
    if (n === null || n <= 0) return null;
    if (!upscale && n > 100) return null;
    return { size: { kind: "pct", n }, upscale };
  }

  if (token.startsWith("!")) {
    const confinedParts = token.slice(1).split(",");
    if (confinedParts.length !== 2) return null;
    const w = parsePositiveInt(confinedParts[0]!);
    const h = parsePositiveInt(confinedParts[1]!);
    if (w === null || h === null) return null;
    return { size: { kind: "confined", w, h }, upscale };
  }

  const parts = token.split(",");
  if (parts.length !== 2) return null;
  const [left, right] = parts;
  if (left !== "" && right === "") {
    const w = parsePositiveInt(left!);
    return w === null ? null : { size: { kind: "w", w }, upscale };
  }
  if (left === "" && right !== "") {
    const h = parsePositiveInt(right!);
    return h === null ? null : { size: { kind: "h", h }, upscale };
  }
  if (left !== "" && right !== "") {
    const w = parsePositiveInt(left!);
    const h = parsePositiveInt(right!);
    if (w === null || h === null) return null;
    return { size: { kind: "wh", w, h }, upscale };
  }
  return null;
}

function parseRotation(token: string): IiifRotation | null {
  const mirror = token.startsWith("!");
  const body = mirror ? token.slice(1) : token;
  if (!/^\d+(\.\d+)?$/.test(body)) return null;
  const degrees = Number(body);
  if (!Number.isFinite(degrees) || degrees < 0 || degrees > 360) return null;
  return { degrees: degrees === 360 ? 0 : degrees, mirror };
}

export function parseIiifTail(tail: string): IiifState | null {
  const segments = tail.split("/").filter(Boolean);
  if (segments.length !== 5) return null;

  const [id, regionToken, sizeToken, rotationToken, qualityFormat] = segments as [
    string,
    string,
    string,
    string,
    string,
  ];

  const source = sourceForIiifId(id);
  if (source === null) return null;

  const region = parseRegion(regionToken);
  if (region === null) return null;

  const parsedSize = parseSize(sizeToken);
  if (parsedSize === null) return null;

  const rotation = parseRotation(rotationToken);
  if (rotation === null) return null;

  const dot = qualityFormat.lastIndexOf(".");
  if (dot <= 0 || dot === qualityFormat.length - 1) return null;
  const quality = qualityFormat.slice(0, dot);
  const format = qualityFormat.slice(dot + 1);
  if (!iiifQualities.includes(quality as IiifQuality)) return null;
  if (!iiifFormats.includes(format as IiifFormat)) return null;

  return {
    source,
    region,
    size: parsedSize.size,
    upscale: parsedSize.upscale,
    rotation,
    quality: quality as IiifQuality,
    format: format as IiifFormat,
  };
}

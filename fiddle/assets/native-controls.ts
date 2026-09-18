import { sampleImages, type SourceImage } from "./source";
export type { SourceImage } from "./source";

export type ResizeMode = "contain" | "cover" | "cover-down" | "stretch" | "auto";
export type Gravity =
  | "center"
  | "top"
  | "bottom"
  | "right"
  | "left"
  | "top-right"
  | "top-left"
  | "bottom-right"
  | "bottom-left";
export type GravityMode =
  | "anchor"
  | "focalPoint"
  | "offset"
  | "smart"
  | "smartFace"
  | "objFace"
  | "object";

// Sub-mode for the unified "object" gravity mode.
export type ObjSubMode = "simple" | "weighted";
export type CropDimensionUnit = "px" | "percent" | "full";
export type ResizeDimensionUnit = "px" | "auto";
export type OutputFormat = "jxl" | "webp" | "avif" | "jpeg" | "png";
export type ColorProfile = "none" | "srgb" | "display-p3" | "adobe-rgb";
export type AutoqualityMethod = "none" | "size" | "ssimulacra2" | "butteraugli";
export type Flip = "none" | "horizontal" | "vertical" | "both";
export type Rotate = number;
// COCO-80 object classes in underscore spelling, matching the hardcoded list in
// ImagePipe.Transform.Detector.ImageVision.Objects (@coco_classes).
export const cocoClasses = [
  "person",
  "bicycle",
  "car",
  "motorcycle",
  "airplane",
  "bus",
  "train",
  "truck",
  "boat",
  "traffic_light",
  "fire_hydrant",
  "stop_sign",
  "parking_meter",
  "bench",
  "bird",
  "cat",
  "dog",
  "horse",
  "sheep",
  "cow",
  "elephant",
  "bear",
  "zebra",
  "giraffe",
  "backpack",
  "umbrella",
  "handbag",
  "tie",
  "suitcase",
  "frisbee",
  "skis",
  "snowboard",
  "sports_ball",
  "kite",
  "baseball_bat",
  "baseball_glove",
  "skateboard",
  "surfboard",
  "tennis_racket",
  "bottle",
  "wine_glass",
  "cup",
  "fork",
  "knife",
  "spoon",
  "bowl",
  "banana",
  "apple",
  "sandwich",
  "orange",
  "broccoli",
  "carrot",
  "hot_dog",
  "pizza",
  "donut",
  "cake",
  "chair",
  "couch",
  "potted_plant",
  "bed",
  "dining_table",
  "toilet",
  "tv",
  "laptop",
  "mouse",
  "remote",
  "keyboard",
  "cell_phone",
  "microwave",
  "oven",
  "toaster",
  "sink",
  "refrigerator",
  "book",
  "clock",
  "vase",
  "scissors",
  "teddy_bear",
  "hair_drier",
  "toothbrush",
] as const;

export type CocoClass = (typeof cocoClasses)[number];

export type TrimBackgroundMode = "auto" | "color";

export type WebpCompression = "lossy" | "near_lossless" | "lossless";
export type WebpPreset = "default" | "photo" | "picture" | "drawing" | "icon" | "text";
export type AvifSubsample = "auto" | "on" | "off";

export type JpegOptionsState = {
  progressive?: boolean;
  no_subsample?: boolean;
  trellis_quant?: boolean;
  overshoot_deringing?: boolean;
  optimize_scans?: boolean;
  quant_table?: number;
};

export type PngOptionsState = {
  interlaced?: boolean;
  quantize?: boolean;
  bitdepth?: number;
};

export type WebpOptionsState = {
  compression?: WebpCompression;
  smart_subsample?: boolean;
  preset?: WebpPreset;
};

export type AvifOptionsState = {
  subsample?: AvifSubsample;
};

export type ControlState = {
  source: SourceImage;
  autoRotateEnabled: boolean;
  flip: Flip;
  rotate: Rotate;
  trimEnabled: boolean;
  trimThreshold: number;
  trimBackgroundMode: TrimBackgroundMode;
  trimColor: string;
  trimEqualHor: boolean;
  trimEqualVer: boolean;
  resizeEnabled: boolean;
  resizeMode: ResizeMode;
  resizeWidthUnit: ResizeDimensionUnit;
  width: number;
  resizeHeightUnit: ResizeDimensionUnit;
  height: number;
  resizeExtendEnabled: boolean;
  zoomEnabled: boolean;
  zoom: number;
  dprEnabled: boolean;
  dpr: number;
  minWidthEnabled: boolean;
  minWidth: number;
  minHeightEnabled: boolean;
  minHeight: number;
  aspectCanvasEnabled: boolean;
  aspectCanvasGravity: Gravity;
  paddingEnabled: boolean;
  paddingTop: number;
  paddingRight: number;
  paddingBottom: number;
  paddingLeft: number;
  backgroundEnabled: boolean;
  backgroundColor: string;
  backgroundAlpha: number;
  blurEnabled: boolean;
  blur: number;
  sharpenEnabled: boolean;
  sharpen: number;
  pixelateEnabled: boolean;
  pixelate: number;
  monochromeEnabled: boolean;
  monochromeIntensity: number;
  monochromeColor: string;
  duotoneEnabled: boolean;
  duotoneIntensity: number;
  duotoneShadow: string;
  duotoneHighlight: string;
  brightnessEnabled: boolean;
  brightness: number;
  contrastEnabled: boolean;
  contrast: number;
  saturationEnabled: boolean;
  saturation: number;
  colorizeEnabled: boolean;
  colorizeOpacity: number;
  colorizeColor: string;
  colorizeKeepAlpha: boolean;
  gradientEnabled: boolean;
  gradientOpacity: number;
  gradientColor: string;
  gradientDirection: string;
  gradientStart: number;
  gradientStop: number;
  gravityEnabled: boolean;
  gravityMode: GravityMode;
  gravity: Gravity;
  gravityFocalX: number;
  gravityFocalY: number;
  gravityOffsetX: number;
  gravityOffsetY: number;
  gravityOffsetXUnit: "px" | "percent";
  gravityOffsetYUnit: "px" | "percent";
  // Unified object-gravity sub-mode (used when gravityMode === "object").
  objSubMode: ObjSubMode;
  // Selected object classes. Empty = all objects. May include the
  // pseudo-class "all" in weighted mode to set the baseline weight.
  objSelectedClasses: string[];
  // Per-class weights for weighted sub-mode. Keyed by class name (including "all").
  // Any selected class not in this map defaults to weight 1.
  objWeights: Record<string, number>;
  enlarge: boolean;
  cropEnabled: boolean;
  cropWidthUnit: CropDimensionUnit;
  cropWidth: number;
  cropWidthPercent: number;
  cropHeightUnit: CropDimensionUnit;
  cropHeight: number;
  cropHeightPercent: number;
  cropAspectRatioEnabled: boolean;
  cropAspectRatio: number;
  cropAspectRatioEnlarge: boolean;
  formatEnabled: boolean;
  format: OutputFormat;
  qualityEnabled: boolean;
  quality: number;
  autoqualityMethod: AutoqualityMethod;
  autoqualitySizeTarget: number;
  autoqualitySsim2Target: number;
  autoqualityButteraugliTarget: number;
  autoqualityMinQuality: number;
  autoqualityMaxQuality: number;
  autoqualityAllowedError: number;
  maxBytesEnabled: boolean;
  maxBytes: number;
  stripMetadata: boolean;
  keepCopyright: boolean;
  stripColorProfile: boolean;
  colorProfile: ColorProfile;
  preserveHdr: boolean;
  jpegOptions: JpegOptionsState;
  pngOptions: PngOptionsState;
  webpOptions: WebpOptionsState;
  avifOptions: AvifOptionsState;
};

export type NumericControlLimit = {
  min: number;
  max: number;
  step: number;
};

export type ImageDimensionAxis = "width" | "height";

type FocalPickerBounds = {
  left: number;
  top: number;
  width: number;
  height: number;
};

export const controlLimits = {
  resize: {
    width: { min: 1, max: 1600, step: 1 },
    height: { min: 1, max: 1000, step: 1 },
  },
  crop: {
    percent: { min: 1, max: 99, step: 1 },
  },
  scale: {
    zoom: { min: 0.1, max: 4, step: 0.1 },
    dpr: { min: 0.1, max: 4, step: 0.1 },
    minWidth: { min: 1, max: 1600, step: 1 },
    minHeight: { min: 1, max: 1000, step: 1 },
  },
  padding: { min: 0, max: 240, step: 1 },
  alpha: { min: 0, max: 1, step: 0.1 },
  effects: {
    blur: { min: 0.1, max: 10, step: 0.1 },
    sharpen: { min: 0.1, max: 10, step: 0.1 },
    pixelate: { min: 2, max: 80, step: 1 },
    intensity: { min: 0, max: 1, step: 0.01 },
    brightness: { min: -255, max: 255, step: 1 },
    contrast: { min: 0.05, max: 4, step: 0.05 },
    saturation: { min: 0.05, max: 4, step: 0.05 },
  },
  focalPoint: { min: 0, max: 1, step: 0.01 },
  gravityOffset: { min: -200, max: 200, step: 0.01 },
  quality: { min: 1, max: 100, step: 1 },
  autoquality: {
    sizeTarget: { min: 1, max: 5_000_000, step: 1 },
    ssim2Target: { min: 0, max: 100, step: 0.1 },
    butteraugliTarget: { min: 0, max: 25, step: 0.1 },
    quality: { min: 1, max: 100, step: 1 },
    allowedError: { min: 0, max: 100, step: 0.1 },
  },
  maxBytes: { min: 1, max: 5_000_000, step: 1 },
} satisfies {
  resize: Record<ImageDimensionAxis, NumericControlLimit>;
  crop: { percent: NumericControlLimit };
  scale: Record<"zoom" | "dpr" | "minWidth" | "minHeight", NumericControlLimit>;
  padding: NumericControlLimit;
  alpha: NumericControlLimit;
  effects: Record<
    "blur" | "sharpen" | "pixelate" | "intensity" | "brightness" | "contrast" | "saturation",
    NumericControlLimit
  >;
  focalPoint: NumericControlLimit;
  gravityOffset: NumericControlLimit;
  quality: NumericControlLimit;
  autoquality: Record<
    "sizeTarget" | "ssim2Target" | "butteraugliTarget" | "quality" | "allowedError",
    NumericControlLimit
  >;
  maxBytes: NumericControlLimit;
};

export { sampleImages };

const sourceImageDimensions = Object.fromEntries(
  sampleImages.map((image) => [image.path, { width: image.width, height: image.height }]),
) as Record<SourceImage, Record<ImageDimensionAxis, number>>;

export function cropPixelLimit(source: SourceImage, axis: ImageDimensionAxis): NumericControlLimit {
  return { min: 1, max: sourceImageDimensions[source]?.[axis] ?? 1, step: 1 };
}

function sourceDimension(source: SourceImage, axis: ImageDimensionAxis): number {
  return cropPixelLimit(source, axis).max;
}

export function resetCropPixelsToSource(currentState: ControlState): ControlState {
  return {
    ...currentState,
    cropWidth: sourceDimension(currentState.source, "width"),
    cropHeight: sourceDimension(currentState.source, "height"),
  };
}

export const defaultControlState: ControlState = {
  source: "images/dog.jpg",
  autoRotateEnabled: true,
  flip: "none",
  rotate: 0,
  trimEnabled: false,
  trimThreshold: 10,
  trimBackgroundMode: "auto",
  trimColor: "#ffffff",
  trimEqualHor: false,
  trimEqualVer: false,
  resizeEnabled: false,
  resizeMode: "contain",
  resizeWidthUnit: "px",
  width: 640,
  resizeHeightUnit: "px",
  height: 360,
  resizeExtendEnabled: false,
  zoomEnabled: false,
  zoom: 1.5,
  dprEnabled: false,
  dpr: 2,
  minWidthEnabled: false,
  minWidth: 320,
  minHeightEnabled: false,
  minHeight: 180,
  aspectCanvasEnabled: false,
  aspectCanvasGravity: "center",
  paddingEnabled: false,
  paddingTop: 24,
  paddingRight: 24,
  paddingBottom: 24,
  paddingLeft: 24,
  backgroundEnabled: false,
  backgroundColor: "#ffffff",
  backgroundAlpha: 1,
  blurEnabled: false,
  blur: 2,
  sharpenEnabled: false,
  sharpen: 1,
  pixelateEnabled: false,
  pixelate: 8,
  monochromeEnabled: false,
  monochromeIntensity: 0.75,
  monochromeColor: "#b3b3b3",
  duotoneEnabled: false,
  duotoneIntensity: 0.75,
  duotoneShadow: "#112233",
  duotoneHighlight: "#ffeecc",
  brightnessEnabled: false,
  brightness: 20,
  contrastEnabled: false,
  contrast: 1.2,
  saturationEnabled: false,
  saturation: 1.2,
  colorizeEnabled: false,
  colorizeOpacity: 0.5,
  colorizeColor: "#000000",
  colorizeKeepAlpha: false,
  gradientEnabled: false,
  gradientOpacity: 0.5,
  gradientColor: "#000000",
  gradientDirection: "down",
  gradientStart: 0,
  gradientStop: 1,
  gravityEnabled: false,
  gravityMode: "anchor",
  gravity: "center",
  gravityFocalX: 0.5,
  gravityFocalY: 0.5,
  gravityOffsetX: 0,
  gravityOffsetY: 0,
  gravityOffsetXUnit: "px",
  gravityOffsetYUnit: "px",
  objSubMode: "simple",
  objSelectedClasses: [],
  objWeights: {},
  enlarge: false,
  cropEnabled: false,
  cropWidthUnit: "px",
  cropWidth: sourceDimension("images/dog.jpg", "width"),
  cropWidthPercent: 50,
  cropHeightUnit: "px",
  cropHeight: sourceDimension("images/dog.jpg", "height"),
  cropHeightPercent: 50,
  cropAspectRatioEnabled: false,
  cropAspectRatio: 1,
  cropAspectRatioEnlarge: false,
  formatEnabled: false,
  format: "jpeg",
  qualityEnabled: false,
  quality: 85,
  autoqualityMethod: "none",
  autoqualitySizeTarget: 50000,
  autoqualitySsim2Target: 78,
  autoqualityButteraugliTarget: 1,
  autoqualityMinQuality: 70,
  autoqualityMaxQuality: 80,
  autoqualityAllowedError: 1,
  maxBytesEnabled: false,
  maxBytes: 50000,
  stripMetadata: true,
  keepCopyright: true,
  stripColorProfile: true,
  colorProfile: "none",
  preserveHdr: false,
  jpegOptions: {},
  pngOptions: {},
  webpOptions: {},
  avifOptions: {},
};

export function focalPointFromBounds(
  clientX: number,
  clientY: number,
  bounds: FocalPickerBounds,
): { x: number; y: number } {
  if (bounds.width <= 0 || bounds.height <= 0) {
    return { x: 0, y: 0 };
  }

  return {
    x: roundedUnit((clientX - bounds.left) / bounds.width),
    y: roundedUnit((clientY - bounds.top) / bounds.height),
  };
}

function roundedUnit(value: number): number {
  const clamped = Math.min(1, Math.max(0, value));

  return Math.round(clamped * 100) / 100;
}

const requestKeys = new Set([
  "orient",
  "format",
  "q",
  "autoquality",
  "max-bytes",
  "meta",
  "profile",
  "hdr",
  "jpeg-options",
  "png-options",
  "webp-options",
  "avif-options",
]);

function keyOf(segment: string): string {
  return segment.split("=", 1)[0]!;
}

export function optionGroups(options: string): string[][] {
  return options.split(/(?:^|\/)then(?:\/|$)/).map((group) => group.split("/").filter(Boolean));
}

function dimension(unit: CropDimensionUnit, pixels: number, percent: number): string {
  return unit === "full" ? "100pct" : unit === "percent" ? `${percent}pct` : String(pixels);
}

function codecSegment(
  name: string,
  fields: Record<string, string | number | boolean | undefined>,
): string | null {
  const items = Object.entries(fields)
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => (value === true ? key : `${key}:${value}`));
  return items.length ? `${name}=${items.join(",")}` : null;
}

export function controlOptionSegments(s: ControlState): string[] {
  const segments: (string | null)[] = [];
  if (!s.autoRotateEnabled) segments.push("orient=none");
  if (s.rotate !== 0) segments.push(`rotate=${s.rotate}`);
  if (s.flip !== "none")
    segments.push(`flip=${{ horizontal: "h", vertical: "v", both: "hv" }[s.flip]}`);
  if (s.trimEnabled) {
    segments.push(
      s.trimBackgroundMode === "auto"
        ? "trim=auto"
        : `trim=${s.trimColor.replace(/^#/, "")},${s.trimThreshold}`,
    );
    const symmetry = `${s.trimEqualHor ? "h" : ""}${s.trimEqualVer ? "v" : ""}`;
    if (symmetry) segments.push(`trim-symmetry=${symmetry}`);
  }
  if (s.cropEnabled)
    segments.push(
      `crop=${dimension(s.cropWidthUnit, s.cropWidth, s.cropWidthPercent)},${dimension(s.cropHeightUnit, s.cropHeight, s.cropHeightPercent)}`,
    );
  if (s.cropAspectRatioEnabled) {
    segments.push(`crop-ratio=${s.cropAspectRatio}`);
    if (s.cropAspectRatioEnlarge) segments.push("crop-ratio-enlarge");
  }
  if (s.resizeEnabled) {
    segments.push(
      `w=${s.resizeWidthUnit === "auto" ? "auto" : s.width}`,
      `h=${s.resizeHeightUnit === "auto" ? "auto" : s.height}`,
      `fit=${s.resizeMode}`,
    );
    if (s.enlarge) segments.push("enlarge");
    if (s.resizeExtendEnabled) segments.push("extend");
  }
  if (s.zoomEnabled) segments.push(`zoom=${s.zoom}`);
  if (s.dprEnabled) segments.push(`dpr=${s.dpr}`);
  if (s.minWidthEnabled) segments.push(`min-w=${s.minWidth}`);
  if (s.minHeightEnabled) segments.push(`min-h=${s.minHeight}`);
  if (s.gravityEnabled) {
    switch (s.gravityMode) {
      case "focalPoint":
        segments.push(`focus=${s.gravityFocalX},${s.gravityFocalY}`);
        break;
      case "smart":
        segments.push("anchor=smart");
        break;
      case "smartFace":
        segments.push("anchor=smart-face");
        break;
      case "objFace":
        segments.push("detect=face");
        break;
      case "object": {
        const classes = s.objSelectedClasses.length ? [...s.objSelectedClasses].sort() : ["all"];
        segments.push(
          `detect=${classes.map((name) => (s.objSubMode === "weighted" ? `${name}:${s.objWeights[name] ?? 1}` : name)).join(",")}`,
        );
        break;
      }
      default:
        segments.push(`anchor=${s.gravity}`);
        if (s.gravityMode === "offset")
          segments.push(
            `anchor-offset=${dimension(s.gravityOffsetXUnit, s.gravityOffsetX, s.gravityOffsetX)},${dimension(s.gravityOffsetYUnit, s.gravityOffsetY, s.gravityOffsetY)}`,
          );
    }
  }
  if (s.aspectCanvasEnabled) segments.push("extend-ratio");
  if (s.aspectCanvasEnabled || (s.resizeEnabled && s.resizeExtendEnabled))
    segments.push(`extend-at=${s.aspectCanvasGravity}`);
  if (s.paddingEnabled)
    segments.push(`pad=${s.paddingTop},${s.paddingRight},${s.paddingBottom},${s.paddingLeft}`);
  if (s.backgroundEnabled)
    segments.push(
      `bg=${s.backgroundColor.replace(/^#/, "")}${s.backgroundAlpha < 1 ? `,${s.backgroundAlpha}` : ""}`,
    );
  if (s.blurEnabled) segments.push(`blur=${s.blur}`);
  if (s.sharpenEnabled) segments.push(`sharpen=${s.sharpen}`);
  if (s.pixelateEnabled) segments.push(`pixelate=${s.pixelate}`);
  if (s.monochromeEnabled)
    segments.push(`monochrome=${s.monochromeIntensity},${s.monochromeColor.replace(/^#/, "")}`);
  if (s.duotoneEnabled)
    segments.push(
      `duotone=${s.duotoneIntensity},${s.duotoneShadow.replace(/^#/, "")},${s.duotoneHighlight.replace(/^#/, "")}`,
    );
  if (s.brightnessEnabled) segments.push(`brightness=${s.brightness}`);
  if (s.contrastEnabled) segments.push(`contrast=${s.contrast}`);
  if (s.saturationEnabled) segments.push(`saturation=${s.saturation}`);
  if (s.colorizeEnabled)
    segments.push(
      `colorize=${s.colorizeOpacity},${s.colorizeColor.replace(/^#/, "")}${s.colorizeKeepAlpha ? ",keep-alpha" : ""}`,
    );
  if (s.gradientEnabled)
    segments.push(
      `gradient=${s.gradientOpacity},${s.gradientColor.replace(/^#/, "")},${s.gradientDirection},${s.gradientStart},${s.gradientStop}`,
    );
  if (s.formatEnabled) segments.push(`format=${s.format}`);
  if (s.qualityEnabled) segments.push(`q=${s.quality}`);
  if (s.autoqualityMethod !== "none") {
    const target =
      s.autoqualityMethod === "size"
        ? s.autoqualitySizeTarget
        : s.autoqualityMethod === "ssimulacra2"
          ? s.autoqualitySsim2Target
          : s.autoqualityButteraugliTarget;
    segments.push(
      `autoquality=${s.autoqualityMethod},target:${target},min:${s.autoqualityMinQuality},max:${s.autoqualityMaxQuality}${s.autoqualityMethod === "size" ? "" : `,error:${s.autoqualityAllowedError}`}`,
    );
  }
  if (s.maxBytesEnabled) segments.push(`max-bytes=${s.maxBytes}`);
  if (!s.stripMetadata) segments.push("meta=keep");
  else if (!s.keepCopyright) segments.push("meta=strip");
  if (s.colorProfile !== "none") segments.push(`profile=${s.colorProfile}`);
  else if (!s.stripColorProfile) segments.push("profile=preserve");
  if (s.preserveHdr) segments.push("hdr=preserve");
  const jpeg = s.jpegOptions;
  segments.push(
    codecSegment("jpeg-options", {
      progressive: jpeg.progressive,
      subsample: jpeg.no_subsample === undefined ? undefined : jpeg.no_subsample ? "off" : "on",
      "trellis-quant": jpeg.trellis_quant,
      "overshoot-deringing": jpeg.overshoot_deringing,
      "optimize-scans": jpeg.optimize_scans,
      "quant-table": jpeg.quant_table,
    }),
  );
  segments.push(
    codecSegment("png-options", {
      interlace: s.pngOptions.interlaced,
      palette: s.pngOptions.quantize,
      bitdepth: s.pngOptions.bitdepth,
    }),
  );
  const compression = s.webpOptions.compression;
  segments.push(
    codecSegment("webp-options", {
      lossless: compression === undefined ? undefined : compression === "lossless",
      "near-lossless": compression === undefined ? undefined : compression === "near_lossless",
      "smart-subsample": s.webpOptions.smart_subsample,
      preset: s.webpOptions.preset,
    }),
  );
  segments.push(codecSegment("avif-options", { subsample: s.avifOptions.subsample }));
  return segments.filter((segment): segment is string => segment !== null);
}

function color(value = "000000"): string {
  if (/^[a-f0-9]{3}$/i.test(value)) return `#${[...value].map((c) => c + c).join("")}`;
  return /^[a-f0-9]{6}$/i.test(value) ? `#${value}` : value;
}

function fields(value: string): Record<string, string> {
  if (!value) return {};
  return Object.fromEntries(
    value.split(",").map((item) => {
      const [key, raw = "true"] = item.split(":");
      return [key!, raw];
    }),
  );
}

export function controlStateFromOptions(
  options: string,
  source: SourceImage,
  groupIndex = 0,
): ControlState {
  const s = { ...structuredClone(defaultControlState), source };
  s.cropWidth = sourceDimension(source, "width");
  s.cropHeight = sourceDimension(source, "height");
  const groups = optionGroups(options);
  const segments = [
    ...(groups[groupIndex] ?? []).filter((segment) => !requestKeys.has(keyOf(segment))),
    ...groups.flat().filter((segment) => requestKeys.has(keyOf(segment))),
  ];
  if (segments.some((segment) => ["w", "h"].includes(keyOf(segment)))) {
    s.resizeWidthUnit = "auto";
    s.resizeHeightUnit = "auto";
  }
  for (const segment of segments) {
    const [key, value = ""] = segment.split("=");
    const parts = value.split(",");
    switch (key) {
      case "orient":
        s.autoRotateEnabled = value !== "none";
        break;
      case "rotate":
        s.rotate = Number(value);
        break;
      case "flip":
        s.flip =
          ({ h: "horizontal", v: "vertical", hv: "both" } as const)[value as "h" | "v" | "hv"] ??
          "none";
        break;
      case "trim":
        s.trimEnabled = true;
        s.trimBackgroundMode = value === "auto" ? "auto" : "color";
        if (value !== "auto") {
          s.trimColor = color(parts[0]!);
          s.trimThreshold = Number(parts[1] ?? 10);
        }
        break;
      case "trim-symmetry":
        s.trimEqualHor = value.includes("h");
        s.trimEqualVer = value.includes("v");
        break;
      case "crop":
        s.cropEnabled = true;
        for (const [i, axis] of [
          [0, "Width"],
          [1, "Height"],
        ] as const) {
          const part = parts[i] ?? "100pct";
          s[`crop${axis}Unit`] =
            part === "100pct" ? "full" : part.endsWith("pct") ? "percent" : "px";
          s[`crop${axis}${part.endsWith("pct") ? "Percent" : ""}`] = parseFloat(part);
        }
        break;
      case "crop-ratio": {
        const [a, b = "1"] = value.split(":");
        s.cropAspectRatioEnabled = true;
        s.cropAspectRatio = Number(a) / Number(b);
        break;
      }
      case "crop-ratio-enlarge":
        s.cropAspectRatioEnlarge = true;
        break;
      case "w":
      case "h": {
        const axis = key === "w" ? "Width" : "Height";
        s.resizeEnabled = true;
        s[`resize${axis}Unit`] = value === "auto" ? "auto" : "px";
        if (value !== "auto") s[key === "w" ? "width" : "height"] = parseFloat(value);
        break;
      }
      case "fit":
        s.resizeMode = value as ResizeMode;
        break;
      case "enlarge":
        s.enlarge = true;
        break;
      case "extend":
        s.resizeExtendEnabled = true;
        break;
      case "extend-ratio":
        s.aspectCanvasEnabled = true;
        break;
      case "extend-at":
        s.aspectCanvasGravity = value as Gravity;
        break;
      case "zoom":
        s.zoomEnabled = true;
        s.zoom = parseFloat(value);
        break;
      case "dpr":
        s.dprEnabled = true;
        s.dpr = Number(value);
        break;
      case "min-w":
        s.minWidthEnabled = true;
        s.minWidth = Number(value);
        break;
      case "min-h":
        s.minHeightEnabled = true;
        s.minHeight = Number(value);
        break;
      case "anchor":
        s.gravityEnabled = true;
        if (value === "smart" || value === "smart-face")
          s.gravityMode = value === "smart" ? "smart" : "smartFace";
        else {
          s.gravity = value as Gravity;
          if (s.gravityMode !== "offset") s.gravityMode = "anchor";
        }
        break;
      case "anchor-offset":
        s.gravityEnabled = true;
        s.gravityMode = "offset";
        s.gravityOffsetX = parseFloat(parts[0]!);
        s.gravityOffsetY = parseFloat(parts[1]!);
        s.gravityOffsetXUnit = parts[0]!.endsWith("pct") ? "percent" : "px";
        s.gravityOffsetYUnit = parts[1]?.endsWith("pct") ? "percent" : "px";
        break;
      case "focus":
        s.gravityEnabled = true;
        s.gravityMode = "focalPoint";
        s.gravityFocalX = Number(parts[0]);
        s.gravityFocalY = Number(parts[1]);
        break;
      case "detect":
        s.gravityEnabled = true;
        s.gravityMode = value === "face" ? "objFace" : "object";
        s.objSubMode = value.includes(":") ? "weighted" : "simple";
        s.objSelectedClasses = parts.map((item) => item.split(":")[0]!);
        s.objWeights = Object.fromEntries(
          parts.map((item) => {
            const [name, weight = "1"] = item.split(":");
            return [name!, Number(weight)];
          }),
        );
        break;
      case "pad": {
        const [top = 0, right = top, bottom = top, left = right] = parts.map(Number);
        Object.assign(s, {
          paddingEnabled: true,
          paddingTop: top,
          paddingRight: right,
          paddingBottom: bottom,
          paddingLeft: left,
        });
        break;
      }
      case "bg":
        s.backgroundEnabled = true;
        s.backgroundColor = color(parts[0]!);
        s.backgroundAlpha = Number(parts[1] ?? 1);
        break;
      case "blur":
      case "sharpen":
      case "pixelate":
      case "brightness":
      case "contrast":
      case "saturation":
        s[`${key}Enabled`] = true;
        s[key] = Number(value);
        break;
      case "monochrome":
        s.monochromeEnabled = true;
        s.monochromeIntensity = Number(parts[0]);
        s.monochromeColor = color(parts[1] ?? "b3b3b3");
        break;
      case "duotone":
        s.duotoneEnabled = true;
        s.duotoneIntensity = Number(parts[0]);
        s.duotoneShadow = color(parts[1] ?? "000000");
        s.duotoneHighlight = color(parts[2] ?? "ffffff");
        break;
      case "colorize":
        s.colorizeEnabled = true;
        s.colorizeOpacity = Number(parts[0]);
        s.colorizeColor = color(parts[1]!);
        s.colorizeKeepAlpha = parts[2] === "keep-alpha";
        break;
      case "gradient":
        s.gradientEnabled = true;
        s.gradientOpacity = Number(parts[0]);
        s.gradientColor = color(parts[1]!);
        s.gradientDirection = parts[2] ?? "down";
        s.gradientStart = Number(parts[3] ?? 0);
        s.gradientStop = Number(parts[4] ?? 1);
        break;
      case "format":
        s.formatEnabled = true;
        s.format = value as OutputFormat;
        break;
      case "q":
        s.qualityEnabled = true;
        s.quality = Number(value);
        break;
      case "max-bytes":
        s.maxBytesEnabled = true;
        s.maxBytes = Number(value);
        break;
      case "meta":
        s.stripMetadata = value !== "keep";
        s.keepCopyright = value === "copyright";
        break;
      case "profile":
        s.stripColorProfile = value !== "preserve";
        s.colorProfile =
          value === "strip" || value === "preserve" ? "none" : (value as ColorProfile);
        break;
      case "hdr":
        s.preserveHdr = value === "preserve";
        break;
      case "autoquality": {
        s.autoqualityMethod = parts[0] as AutoqualityMethod;
        const f = fields(parts.slice(1).join(","));
        if (s.autoqualityMethod === "butteraugli") s.autoqualityAllowedError = 0.1;
        if (f.target !== undefined) {
          if (s.autoqualityMethod === "size") s.autoqualitySizeTarget = Number(f.target);
          else if (s.autoqualityMethod === "ssimulacra2")
            s.autoqualitySsim2Target = Number(f.target);
          else s.autoqualityButteraugliTarget = Number(f.target);
        }
        if (f.min !== undefined) s.autoqualityMinQuality = Number(f.min);
        if (f.max !== undefined) s.autoqualityMaxQuality = Number(f.max);
        if (f.error !== undefined) s.autoqualityAllowedError = Number(f.error);
        break;
      }
      case "jpeg-options": {
        const f = fields(value);
        for (const name of [
          "progressive",
          "trellis_quant",
          "overshoot_deringing",
          "optimize_scans",
        ] as const) {
          const raw = f[name.replaceAll("_", "-")];
          if (raw !== undefined) s.jpegOptions[name] = raw !== "false";
        }
        if (f.subsample === "on" || f.subsample === "off")
          s.jpegOptions.no_subsample = f.subsample === "off";
        if (f["quant-table"] !== undefined) s.jpegOptions.quant_table = Number(f["quant-table"]);
        break;
      }
      case "png-options": {
        const f = fields(value);
        if (f.interlace !== undefined) s.pngOptions.interlaced = f.interlace !== "false";
        if (f.palette !== undefined) s.pngOptions.quantize = f.palette !== "false";
        if (f.bitdepth !== undefined) s.pngOptions.bitdepth = Number(f.bitdepth);
        break;
      }
      case "webp-options": {
        const f = fields(value);
        if (f.lossless !== undefined || f["near-lossless"] !== undefined)
          s.webpOptions.compression =
            f.lossless === "true"
              ? "lossless"
              : f["near-lossless"] === "true"
                ? "near_lossless"
                : "lossy";
        if (f["smart-subsample"] !== undefined)
          s.webpOptions.smart_subsample = f["smart-subsample"] !== "false";
        if (f.preset !== undefined) s.webpOptions.preset = f.preset as WebpPreset;
        break;
      }
      case "avif-options": {
        const f = fields(value);
        if (f.subsample !== undefined) s.avifOptions.subsample = f.subsample as AvifSubsample;
        break;
      }
    }
  }
  const qualityFields =
    segments.find((segment) => keyOf(segment) === "autoquality")?.split("=")[1] ?? "";
  if (!fields(qualityFields).min && s.formatEnabled) {
    if (s.format === "jxl") s.autoqualityMinQuality = 45;
    if (s.format === "avif") s.autoqualityMinQuality = 60;
  }
  if (!fields(qualityFields).max && s.formatEnabled && s.format === "avif")
    s.autoqualityMaxQuality = 65;
  for (const [key, value] of Object.entries(s)) {
    if (typeof value === "number" && !Number.isFinite(value)) {
      Object.assign(s, { [key]: defaultControlState[key as keyof ControlState] });
    }
  }
  return s;
}

// Keep prerequisites in sync when a user switches a visual tool on or off.
export function normalizeControlEdit(before: ControlState, after: ControlState): ControlState {
  const s = { ...after };
  if (
    s.resizeEnabled &&
    !before.resizeEnabled &&
    s.resizeWidthUnit === "auto" &&
    s.resizeHeightUnit === "auto"
  )
    s.resizeWidthUnit = "px";
  if (s.aspectCanvasEnabled && !before.aspectCanvasEnabled) {
    s.resizeExtendEnabled = false;
    s.resizeEnabled = true;
    s.resizeWidthUnit = "px";
    s.resizeHeightUnit = "px";
  }
  if (s.resizeExtendEnabled && !before.resizeExtendEnabled) {
    s.aspectCanvasEnabled = false;
    s.resizeEnabled = true;
    s.resizeWidthUnit = "px";
    s.resizeHeightUnit = "px";
  }
  if (!s.resizeEnabled && before.resizeEnabled) {
    s.aspectCanvasEnabled = false;
    s.resizeExtendEnabled = false;
    s.zoomEnabled = false;
    if (!s.cropEnabled) s.gravityEnabled = false;
  }
  if (s.cropAspectRatioEnabled && !before.cropAspectRatioEnabled) s.cropEnabled = true;
  if (!s.cropEnabled && before.cropEnabled) {
    s.cropAspectRatioEnabled = false;
    if (!s.resizeEnabled || !["cover", "cover-down", "auto"].includes(s.resizeMode))
      s.gravityEnabled = false;
  }
  if (s.gravityEnabled && !before.gravityEnabled && !s.cropEnabled) {
    s.resizeEnabled = true;
    if (!["cover", "cover-down", "auto"].includes(s.resizeMode)) s.resizeMode = "cover";
    if (s.resizeWidthUnit === "auto" && s.resizeHeightUnit === "auto") s.resizeWidthUnit = "px";
  }
  if (
    s.zoomEnabled &&
    !before.zoomEnabled &&
    !s.resizeEnabled &&
    !s.minWidthEnabled &&
    !s.minHeightEnabled
  )
    s.resizeEnabled = true;
  if (
    s.resizeMode !== before.resizeMode &&
    !s.cropEnabled &&
    !["cover", "cover-down", "auto"].includes(s.resizeMode)
  )
    s.gravityEnabled = false;
  if (
    s.resizeWidthUnit !== before.resizeWidthUnit ||
    s.resizeHeightUnit !== before.resizeHeightUnit
  ) {
    if (s.resizeWidthUnit === "auto" || s.resizeHeightUnit === "auto") {
      s.aspectCanvasEnabled = false;
      s.resizeExtendEnabled = false;
    }
    if (s.resizeWidthUnit === "auto" && s.resizeHeightUnit === "auto") {
      s.resizeEnabled = false;
      s.zoomEnabled = false;
      if (!s.cropEnabled) s.gravityEnabled = false;
    }
  }
  return s;
}

// Apply only user-edited fields, retaining raw spellings and options without a
// widget. This also keeps native then groups and request-wide options intact.
export function updateControlOptions(
  options: string,
  groupIndex: number,
  before: ControlState,
  after: ControlState,
): string {
  const previous = new Map(
    controlOptionSegments(before).map((segment) => [keyOf(segment), segment]),
  );
  const next = new Map(controlOptionSegments(after).map((segment) => [keyOf(segment), segment]));
  const changedKeys = [...new Set([...previous.keys(), ...next.keys()])].filter(
    (key) => previous.get(key) !== next.get(key),
  );
  if (changedKeys.length === 0) return options;
  const groups = optionGroups(options);
  for (const key of changedKeys) {
    let replacement = next.get(key);
    const target = requestKeys.has(key)
      ? groups.findIndex((group) => group.some((segment) => keyOf(segment) === key))
      : groupIndex;
    const group = groups[target < 0 ? 0 : target]!;
    const index = group.findIndex((segment) => keyOf(segment) === key);
    const oldValue = previous.get(key)?.split("=")[1] ?? "";
    const newValue = replacement?.split("=")[1] ?? "";
    const sameSearch = key === "autoquality" && oldValue.split(",")[0] === newValue.split(",")[0];
    if ((key.endsWith("-options") || sameSearch) && index >= 0) {
      const oldFields = fields(oldValue);
      const newFields = fields(newValue);
      const rawFields = group[index]!.split("=")[1]!.split(",");
      for (const field of new Set([...Object.keys(oldFields), ...Object.keys(newFields)])) {
        if (oldFields[field] === newFields[field]) continue;
        const at = rawFields.findIndex((item) => item.split(":")[0] === field);
        const entry =
          newFields[field] === undefined
            ? []
            : [newFields[field] === "true" ? field : `${field}:${newFields[field]}`];
        if (at >= 0) rawFields.splice(at, 1, ...entry);
        else rawFields.push(...entry);
      }
      replacement = rawFields.length ? `${key}=${rawFields.join(",")}` : undefined;
    }
    if (index >= 0) group.splice(index, 1, ...(replacement === undefined ? [] : [replacement]));
    else if (replacement !== undefined) group.push(replacement);
  }
  const group = groups[groupIndex]!;
  if (
    (before.resizeExtendEnabled || before.aspectCanvasEnabled) &&
    !after.resizeExtendEnabled &&
    !after.aspectCanvasEnabled
  ) {
    groups[groupIndex] = group.filter(
      (segment) => !["extend-at", "extend-offset"].includes(keyOf(segment)),
    );
  }
  if (!before.cropEnabled && after.cropEnabled)
    groups[groupIndex] = groups[groupIndex]!.filter((segment) => keyOf(segment) !== "region");
  return groups
    .filter((group) => group.length > 0)
    .map((group) => group.join("/"))
    .join("/then/");
}

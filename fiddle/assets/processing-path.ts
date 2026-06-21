import { sampleImages } from "virtual:sample-images";

export type ResizeMode = "fit" | "fill" | "fill-down" | "force" | "auto";
export type Gravity = "ce" | "no" | "so" | "ea" | "we" | "noea" | "nowe" | "soea" | "sowe";
export type GravityMode = "anchor" | "focalPoint" | "offset" | "smart" | "objFace" | "object";

// Sub-mode for the unified "object" gravity mode.
export type ObjSubMode = "simple" | "weighted";
export type CropGravity = "inherit" | Gravity | "sm" | "obj:face" | "obj" | "obj:all";
export type CropDimensionUnit = "px" | "percent" | "full";
export type ResizeDimensionUnit = "px" | "auto";
export type OutputFormat = "webp" | "avif" | "jpeg" | "png";
export type ColorProfile = "none" | "srgb" | "display-p3" | "adobe-rgb";
export type AutoqualityMethod = "none" | "size" | "ssim2";
export type Flip = "none" | "horizontal" | "vertical" | "both";
export type Rotate = 0 | 90 | 180 | 270;
export type SignatureMode = "unsigned" | "signed";
export type SourceImage = (typeof sampleImages)[number]["path"];

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

export type FiddleState = {
  signatureMode: SignatureMode;
  signatureKey: string;
  signatureSalt: string;
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
  aspectCanvasGravity: Gravity | "ce";
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
  // Unified object-gravity sub-mode (used when gravityMode === "object").
  objSubMode: ObjSubMode;
  // Selected object classes. Empty = all objects (bare g:obj). May include the
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
  cropGravity: CropGravity;
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
};

export type ProcessedImageMetadata = {
  width: number;
  height: number;
  bytes: number | null;
  contentType: string | null;
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

type ResourceTimingSize = Pick<PerformanceResourceTiming, "name"> &
  Partial<Pick<PerformanceResourceTiming, "decodedBodySize" | "encodedBodySize">>;

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
    minWidth: { min: 0, max: 1600, step: 1 },
    minHeight: { min: 0, max: 1000, step: 1 },
  },
  padding: { min: 0, max: 240, step: 1 },
  alpha: { min: 0, max: 1, step: 0.1 },
  effects: {
    blur: { min: 0.1, max: 10, step: 0.1 },
    sharpen: { min: 0.1, max: 10, step: 0.1 },
    pixelate: { min: 2, max: 80, step: 1 },
    intensity: { min: 0, max: 1, step: 0.01 },
    brightness: { min: -255, max: 255, step: 1 },
    contrast: { min: 0, max: 4, step: 0.05 },
    saturation: { min: 0, max: 4, step: 0.05 },
  },
  focalPoint: { min: 0, max: 1, step: 0.01 },
  gravityOffset: { min: -200, max: 200, step: 0.01 },
  quality: { min: 0, max: 100, step: 1 },
  autoquality: {
    sizeTarget: { min: 1, max: 5_000_000, step: 1 },
    ssim2Target: { min: 0, max: 100, step: 0.1 },
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
    "sizeTarget" | "ssim2Target" | "quality" | "allowedError",
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

export function resetCropPixelsToSource(currentState: FiddleState): FiddleState {
  return {
    ...currentState,
    cropWidth: sourceDimension(currentState.source, "width"),
    cropHeight: sourceDimension(currentState.source, "height"),
  };
}

export function debounce<Arguments extends unknown[]>(
  callback: (...args: Arguments) => void,
  delayMs: number,
): (...args: Arguments) => void {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;

  return (...args: Arguments) => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }

    timeoutId = setTimeout(() => {
      callback(...args);
    }, delayMs);
  };
}

export const defaultFiddleState: FiddleState = {
  signatureMode: "unsigned",
  signatureKey: "736563726574",
  signatureSalt: "68656c6c6f",
  source: "images/dog.jpg",
  autoRotateEnabled: false,
  flip: "none",
  rotate: 0,
  trimEnabled: false,
  trimThreshold: 10,
  trimBackgroundMode: "auto",
  trimColor: "#ffffff",
  trimEqualHor: false,
  trimEqualVer: false,
  resizeEnabled: false,
  resizeMode: "fill",
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
  aspectCanvasGravity: "ce",
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
  gravity: "ce",
  gravityFocalX: 0.5,
  gravityFocalY: 0.5,
  gravityOffsetX: 0,
  gravityOffsetY: 0,
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
  cropGravity: "inherit",
  cropAspectRatioEnabled: false,
  cropAspectRatio: 1,
  cropAspectRatioEnlarge: false,
  formatEnabled: false,
  format: "jpeg",
  qualityEnabled: false,
  quality: 85,
  autoqualityMethod: "none",
  autoqualitySizeTarget: 50000,
  autoqualitySsim2Target: 90,
  autoqualityMinQuality: 70,
  autoqualityMaxQuality: 90,
  autoqualityAllowedError: 1,
  maxBytesEnabled: false,
  maxBytes: 50000,
  stripMetadata: true,
  keepCopyright: true,
  stripColorProfile: true,
  colorProfile: "none",
  preserveHdr: false,
};

export function optionSegments(currentState: FiddleState): string[] {
  const segments: string[] = [];

  if (currentState.autoRotateEnabled) {
    segments.push("ar:1");
  }

  if (currentState.flip === "horizontal") {
    segments.push("fl:1");
  }

  if (currentState.flip === "vertical") {
    segments.push("fl:0:1");
  }

  if (currentState.flip === "both") {
    segments.push("fl");
  }

  if (currentState.rotate !== 0) {
    segments.push(`rot:${currentState.rotate}`);
  }

  const trimSeg = trimOptionSegment(currentState);

  if (trimSeg !== null) {
    segments.push(trimSeg);
  }

  const cropSegment = cropOptionSegment(currentState);

  if (cropSegment !== null) {
    segments.push(cropSegment);
  }

  // Emit whenever the toggle is on, independent of cropEnabled, so the segment
  // round-trips with parseFiddlePath (which sets cropAspectRatioEnabled alone).
  if (currentState.cropAspectRatioEnabled) {
    segments.push(
      currentState.cropAspectRatioEnlarge
        ? `car:${currentState.cropAspectRatio}:1`
        : `car:${currentState.cropAspectRatio}`,
    );
  }

  const resizeSegment = resizeOptionSegment(currentState);

  if (resizeSegment !== null) {
    segments.push(resizeSegment);
  }

  if (currentState.zoomEnabled) {
    segments.push(`z:${currentState.zoom}`);
  }

  if (currentState.dprEnabled) {
    segments.push(`dpr:${currentState.dpr}`);
  }

  if (currentState.minWidthEnabled) {
    segments.push(`mw:${currentState.minWidth}`);
  }

  if (currentState.minHeightEnabled) {
    segments.push(`mh:${currentState.minHeight}`);
  }

  if (currentState.aspectCanvasEnabled) {
    segments.push(
      currentState.aspectCanvasGravity === "ce"
        ? "exar:1"
        : `exar:1:${currentState.aspectCanvasGravity}`,
    );
  }

  if (currentState.paddingEnabled) {
    segments.push(
      [
        "pd",
        currentState.paddingTop,
        currentState.paddingRight,
        currentState.paddingBottom,
        currentState.paddingLeft,
      ].join(":"),
    );
  }

  if (currentState.backgroundEnabled) {
    segments.push(`bg:${currentState.backgroundColor.replace(/^#/, "")}`);

    if (currentState.backgroundAlpha < 1) {
      segments.push(`bga:${currentState.backgroundAlpha}`);
    }
  }

  if (currentState.blurEnabled) {
    segments.push(`bl:${currentState.blur}`);
  }

  if (currentState.sharpenEnabled) {
    segments.push(`sh:${currentState.sharpen}`);
  }

  if (currentState.pixelateEnabled) {
    segments.push(`pix:${currentState.pixelate}`);
  }

  if (currentState.monochromeEnabled) {
    segments.push(
      `mc:${currentState.monochromeIntensity}:${currentState.monochromeColor.replace(/^#/, "")}`,
    );
  }

  if (currentState.duotoneEnabled) {
    segments.push(
      [
        "dt",
        currentState.duotoneIntensity,
        currentState.duotoneShadow.replace(/^#/, ""),
        currentState.duotoneHighlight.replace(/^#/, ""),
      ].join(":"),
    );
  }

  if (currentState.brightnessEnabled) {
    segments.push(`br:${currentState.brightness}`);
  }

  if (currentState.contrastEnabled) {
    segments.push(`co:${currentState.contrast}`);
  }

  if (currentState.saturationEnabled) {
    segments.push(`sa:${currentState.saturation}`);
  }

  if (currentState.colorizeEnabled) {
    segments.push(
      `col:${currentState.colorizeOpacity}:${currentState.colorizeColor.replace(/^#/, "")}:${
        currentState.colorizeKeepAlpha ? 1 : 0
      }`,
    );
  }

  if (currentState.gradientEnabled) {
    segments.push(
      `gr:${currentState.gradientOpacity}:${currentState.gradientColor.replace(/^#/, "")}:${
        currentState.gradientDirection
      }:${currentState.gradientStart}:${currentState.gradientStop}`,
    );
  }

  if (currentState.gravityEnabled) {
    segments.push(gravitySegment(currentState));
  }

  if (currentState.formatEnabled) {
    segments.push(`f:${currentState.format}`);
  }

  if (currentState.qualityEnabled) {
    segments.push(`q:${currentState.quality}`);
  }

  const autoqualitySegment = autoqualityOptionSegment(currentState);

  if (autoqualitySegment !== null) {
    segments.push(autoqualitySegment);
  }

  if (currentState.maxBytesEnabled && currentState.maxBytes > 0) {
    segments.push(`mb:${currentState.maxBytes}`);
  }

  if (!currentState.stripMetadata) {
    segments.push("sm:0");
  } else if (!currentState.keepCopyright) {
    segments.push("kcr:0");
  }

  if (!currentState.stripColorProfile) {
    segments.push("scp:0");
  }

  if (currentState.colorProfile !== "none") {
    segments.push(`cp:${currentState.colorProfile}`);
  }

  if (currentState.preserveHdr) {
    segments.push("ph:1");
  }

  return segments;
}

// autoquality:size:%target:%min:%max | autoquality:ssim2:%target:%min:%max:%allowed_error
// "none" disables the search and emits nothing.
export function autoqualityOptionSegment(currentState: FiddleState): string | null {
  if (currentState.autoqualityMethod === "size") {
    return [
      "autoquality",
      "size",
      currentState.autoqualitySizeTarget,
      currentState.autoqualityMinQuality,
      currentState.autoqualityMaxQuality,
    ].join(":");
  }

  if (currentState.autoqualityMethod === "ssim2") {
    return [
      "autoquality",
      "ssim2",
      currentState.autoqualitySsim2Target,
      currentState.autoqualityMinQuality,
      currentState.autoqualityMaxQuality,
      currentState.autoqualityAllowedError,
    ].join(":");
  }

  return null;
}

export function trimOptionSegment(currentState: FiddleState): string | null {
  if (!currentState.trimEnabled) {
    return null;
  }

  const parts: string[] = ["trim", String(currentState.trimThreshold)];

  const colorHex =
    currentState.trimBackgroundMode === "color" ? currentState.trimColor.replace(/^#/, "") : "";

  // Append color, equal_hor, equal_ver only when needed (drop trailing empty args).
  const eh = currentState.trimEqualHor ? "1" : "0";
  const ev = currentState.trimEqualVer ? "1" : "0";

  if (currentState.trimEqualHor || currentState.trimEqualVer) {
    parts.push(colorHex, eh, ev);
  } else if (colorHex !== "") {
    parts.push(colorHex);
  }

  return parts.join(":");
}

export function cropOptionSegment(currentState: FiddleState): string | null {
  if (!currentState.cropEnabled) {
    return null;
  }

  const cropSegment = [
    "c",
    cropDimensionSegment(
      currentState.cropWidthUnit,
      currentState.cropWidth,
      currentState.cropWidthPercent,
    ),
    cropDimensionSegment(
      currentState.cropHeightUnit,
      currentState.cropHeight,
      currentState.cropHeightPercent,
    ),
  ];

  if (currentState.cropGravity !== "inherit") {
    cropSegment.push(currentState.cropGravity);
  }

  return cropSegment.join(":");
}

export function resizeOptionSegment(currentState: FiddleState): string | null {
  if (!currentState.resizeEnabled) {
    return null;
  }

  const resizeSegment = [
    "rs",
    currentState.resizeMode,
    resizeDimensionSegment(currentState.resizeWidthUnit, currentState.width),
    resizeDimensionSegment(currentState.resizeHeightUnit, currentState.height),
    currentState.enlarge ? 1 : 0,
  ];

  if (currentState.resizeExtendEnabled) {
    resizeSegment.push(1);
  }

  return resizeSegment.join(":");
}

export function cropDimensionSegment(
  unit: CropDimensionUnit,
  pixels: number,
  percent: number,
): string {
  if (unit === "full") {
    return "0";
  }

  if (unit === "percent") {
    return String(percent / 100);
  }

  return String(Math.max(1, pixels));
}

export function resizeDimensionSegment(unit: ResizeDimensionUnit, pixels: number): string {
  if (unit === "auto") {
    return "0";
  }

  return String(pixels);
}

export function gravitySegment(currentState: FiddleState): string {
  if (currentState.gravityMode === "smart") {
    return "g:sm";
  }

  if (currentState.gravityMode === "objFace") {
    return "g:obj:face";
  }

  if (currentState.gravityMode === "object") {
    return objGravitySegmentFromState(currentState);
  }

  if (currentState.gravityMode === "focalPoint") {
    return `g:fp:${currentState.gravityFocalX}:${currentState.gravityFocalY}`;
  }

  if (currentState.gravityMode === "offset") {
    return `g:${currentState.gravity}:${currentState.gravityOffsetX}:${currentState.gravityOffsetY}`;
  }

  return `g:${currentState.gravity}`;
}

export function objGravitySegment(classes: string[]): string {
  if (classes.length === 0) {
    return "g:obj";
  }

  return `g:obj:${classes.join(":")}`;
}

// Builds the g:obj or g:objw segment from the unified object-gravity state.
//
// Rules:
// - Empty selection (either sub-mode) → g:obj (all objects).
// - Simple sub-mode → g:obj:<class>... (sorted for stable URLs); empty → g:obj.
// - Weighted sub-mode:
//   - All selected weights equal (uniform) → emit g:obj form (a uniform weight
//     is inert for filtering; the class list still filters detection).
//   - Otherwise → emit g:objw:<class>:<weight>... for ALL selected classes
//     verbatim, including class:1 entries (the class token is load-bearing).
export function objGravitySegmentFromState(currentState: FiddleState): string {
  const { objSubMode, objSelectedClasses, objWeights } = currentState;

  if (objSelectedClasses.length === 0) {
    return "g:obj";
  }

  if (objSubMode === "simple") {
    const sorted = [...objSelectedClasses].sort();

    return `g:obj:${sorted.join(":")}`;
  }

  // Weighted sub-mode: check whether all selected weights are equal (uniform).
  const weights = objSelectedClasses.map((cls) => objWeights[cls] ?? 1);
  const firstWeight = weights[0] ?? 1;
  const allUniform = weights.every((w) => w === firstWeight);

  if (allUniform) {
    // Uniform weights are inert — emit the compact obj form.
    const sorted = [...objSelectedClasses].sort();

    return `g:obj:${sorted.join(":")}`;
  }

  // Non-uniform: emit g:objw verbatim (sorted by class name for stable URLs).
  const sorted = [...objSelectedClasses].sort();
  const pairs = sorted.flatMap((cls) => [cls, String(objWeights[cls] ?? 1)]);

  return `g:objw:${pairs.join(":")}`;
}

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

export function resolvedOutputLabel(
  currentState: FiddleState,
  metadata: ProcessedImageMetadata | null = null,
): string {
  if (!currentState.formatEnabled) {
    const negotiatedFormat = outputFormatFromContentType(metadata?.contentType ?? null);

    if (negotiatedFormat !== null) {
      return `auto -> ${negotiatedFormat}`;
    }

    return "auto";
  }

  return currentState.format;
}

function outputFormatFromContentType(contentType: string | null): string | null {
  if (contentType === null) {
    return null;
  }

  const [mimeType] = contentType.toLowerCase().split(";");

  if (mimeType === "image/jpeg") {
    return "jpeg";
  }

  return mimeType?.startsWith("image/") === true ? mimeType.slice("image/".length) : null;
}

export function processedSizeLabel(metadata: ProcessedImageMetadata | null): string {
  if (metadata === null) {
    return "Loading";
  }

  const dimensions = `${metadata.width} × ${metadata.height}`;

  if (metadata.bytes === null) {
    return dimensions;
  }

  const kilobytes = Math.max(1, Math.round(metadata.bytes / 1024));

  return `${dimensions} (${kilobytes} kB)`;
}

export function imageRequestBytesFromPerformance(
  imageUrl: string,
  entries: readonly ResourceTimingSize[],
): number | null {
  const matchingEntries = entries.filter((entry) => entry.name === imageUrl);

  for (const entry of matchingEntries.toReversed()) {
    const bytes = entry.encodedBodySize || entry.decodedBodySize || 0;

    if (bytes > 0) {
      return bytes;
    }
  }

  return null;
}

export function sourceIdentifierForRequest(source: SourceImage): string {
  return `local:///${source}`;
}

export function signedPathForState(currentState: FiddleState): string {
  const options = optionSegments(currentState).join("/");
  const optionsPath = options === "" ? "" : `/${options}`;

  return `${optionsPath}/plain/${sourceIdentifierForRequest(currentState.source)}`;
}

const processingPrefix = "/img";

export function processingPathFromSignedPath(signature: string, signedPath: string): string {
  return `${processingPrefix}/${signature}${signedPath}`;
}

export function buildProcessingPath(currentState: FiddleState, signature?: string): string {
  const signedPath = signedPathForState(currentState);

  if (signature !== undefined) {
    return processingPathFromSignedPath(signature, signedPath);
  }

  return processingPathFromSignedPath(signatureSegment(), signedPath);
}

export async function signProcessingPath(
  signedPath: string,
  keyHex: string,
  saltHex: string,
  signatureSize = 32,
): Promise<string> {
  if (!Number.isInteger(signatureSize) || signatureSize < 1 || signatureSize > 32) {
    throw new RangeError("signatureSize must be an integer between 1 and 32");
  }

  const key = hexToBytes(keyHex, "key");
  const salt = hexToBytes(saltHex, "salt");
  const pathBytes = new TextEncoder().encode(signedPath);
  const data = new Uint8Array(salt.length + pathBytes.length);

  data.set(salt);
  data.set(pathBytes, salt.length);

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    toArrayBuffer(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, toArrayBuffer(data)));
  const signature = digest.slice(0, signatureSize);

  return base64UrlEncode(signature);
}

function signatureSegment(): string {
  return "_";
}

function hexToBytes(hex: string, label: string): Uint8Array {
  if (hex === "" || hex.length % 2 !== 0 || !/^[\da-f]+$/i.test(hex)) {
    throw new Error(`Signing ${label} must be a non-empty hex string`);
  }

  const bytes = new Uint8Array(hex.length / 2);

  for (let index = 0; index < hex.length; index += 2) {
    bytes[index / 2] = Number.parseInt(hex.slice(index, index + 2), 16);
  }

  return bytes;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer = new ArrayBuffer(bytes.byteLength);

  new Uint8Array(buffer).set(bytes);

  return buffer;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

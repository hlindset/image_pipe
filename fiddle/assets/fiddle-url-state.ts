import {
  defaultFiddleState,
  resetCropPixelsToSource,
  sampleImages,
  signedPathForState,
  type ColorProfile,
  type CropDimensionUnit,
  type CropGravity,
  type FiddleState,
  type Flip,
  type Gravity,
  type OutputFormat,
  type ResizeDimensionUnit,
  type ResizeMode,
  type Rotate,
  type SourceImage,
  type ObjSubMode,
  type TrimBackgroundMode,
} from "./processing-path";
import { defaultIiifState, iiifBrowserPath, parseIiifTail, type IiifState } from "./iiif-path";
import {
  defaultTwicPicsState,
  parseTwicTail,
  twicBrowserPath,
  type TwicPicsState,
} from "./twicpics-path";

// Classes offered in the fiddle's object-gravity UI. A subset of COCO-80 chosen
// to match the default source images (dog, cat) and the most common fiddles
// (person, face). "all" is the pseudo-class for the weighted baseline.
export const fiddleObjClasses = ["face", "person", "car", "dog", "cat"] as const;
const fiddleObjClassSet = new Set<string>(fiddleObjClasses);

export type ExpandedToolboxes = {
  effectsOpen: boolean;
  orientationOpen: boolean;
  requestOpen: boolean;
  scaleOptionsOpen: boolean;
};

type ParsedDimension<Unit> = {
  unit: Unit;
  value: number;
};

const plainSourceMarker = "/plain/";
const localSourcePrefix = "local:///";
const sourceImages = new Set<string>(sampleImages.map((image) => image.path));
const resizeModes = new Set<string>(["fit", "fill", "fill-down", "force", "auto"]);
const gravityValues = new Set<string>([
  "ce",
  "no",
  "so",
  "ea",
  "we",
  "noea",
  "nowe",
  "soea",
  "sowe",
]);
const outputFormats = new Set<string>(["webp", "avif", "jpeg", "png"]);
const colorProfileAliases = new Map<string, ColorProfile>([
  ["srgb", "srgb"],
  ["p3", "display-p3"],
  ["display-p3", "display-p3"],
  ["adobe-rgb", "adobe-rgb"],
  ["adobergb", "adobe-rgb"],
]);
const rotations = new Set<number>([90, 180, 270]);

export function fiddlePathForState(currentState: FiddleState): string {
  return signedPathForState(currentState);
}

export function parseFiddlePath(pathname: string): FiddleState {
  const parsed = parseFiddlePathParts(pathname);

  if (parsed === null) {
    return { ...defaultFiddleState };
  }

  let state = resetCropPixelsToSource({
    ...defaultFiddleState,
    source: parsed.source,
  });

  for (const segment of parsed.optionSegments) {
    const nextState = applyOptionSegment(state, segment);

    if (nextState === null) {
      return { ...defaultFiddleState };
    }

    state = nextState;
  }

  return state;
}

export function resetFiddleSettings(currentState: FiddleState): FiddleState {
  return resetCropPixelsToSource({
    ...defaultFiddleState,
    source: currentState.source,
    signatureMode: currentState.signatureMode,
    signatureKey: currentState.signatureKey,
    signatureSalt: currentState.signatureSalt,
  });
}

export function expandedToolboxesForState(currentState: FiddleState): ExpandedToolboxes {
  return {
    effectsOpen:
      currentState.blurEnabled ||
      currentState.sharpenEnabled ||
      currentState.pixelateEnabled ||
      currentState.monochromeEnabled ||
      currentState.duotoneEnabled ||
      currentState.brightnessEnabled ||
      currentState.contrastEnabled ||
      currentState.saturationEnabled ||
      currentState.colorizeEnabled ||
      currentState.gradientEnabled,
    orientationOpen:
      currentState.autoRotateEnabled || currentState.flip !== "none" || currentState.rotate !== 0,
    requestOpen: true,
    scaleOptionsOpen:
      currentState.zoomEnabled ||
      currentState.dprEnabled ||
      currentState.minWidthEnabled ||
      currentState.minHeightEnabled,
  };
}

function parseFiddlePathParts(
  pathname: string,
): { optionSegments: string[]; source: SourceImage } | null {
  const path = pathname.endsWith("/") && pathname !== "/" ? pathname.slice(0, -1) : pathname;

  const plainIndex = path.indexOf(plainSourceMarker);

  if (plainIndex === -1) {
    return null;
  }

  const optionSegments = path.slice(0, plainIndex).split("/").filter(Boolean);
  const source = sourceFromIdentifier(path.slice(plainIndex + plainSourceMarker.length));

  if (source === null) {
    return null;
  }

  return {
    optionSegments,
    source,
  };
}

function sourceFromIdentifier(identifier: string): SourceImage | null {
  if (!identifier.startsWith(localSourcePrefix)) {
    return null;
  }

  const source = identifier.slice(localSourcePrefix.length);
  return sourceImages.has(source) ? (source as SourceImage) : null;
}

function applyOptionSegment(currentState: FiddleState, segment: string): FiddleState | null {
  const [name = "", ...args] = segment.split(":");

  switch (name) {
    case "ar":
      return parseAutoRotate(currentState, args);

    case "t":
    case "trim":
      return parseTrim(currentState, args);

    case "fl":
      return parseFlip(currentState, args);

    case "rot":
      return parseRotate(currentState, args);

    case "c":
    case "crop":
      return parseCrop(currentState, args);

    case "car":
    case "crop_ar":
    case "crop_aspect_ratio":
      return parseCropAspectRatio(currentState, args);

    case "rs":
    case "resize":
      return parseResize(currentState, args);

    case "z":
      return parseNumericOption(currentState, args, (value) => ({
        zoomEnabled: true,
        zoom: value,
      }));

    case "dpr":
      return parseNumericOption(currentState, args, (value) => ({ dprEnabled: true, dpr: value }));

    case "mw":
      return parseNumericOption(currentState, args, (value) => ({
        minWidthEnabled: true,
        minWidth: value,
      }));

    case "mh":
      return parseNumericOption(currentState, args, (value) => ({
        minHeightEnabled: true,
        minHeight: value,
      }));

    case "exar":
      return parseAspectCanvas(currentState, args);

    case "pd":
      return parsePadding(currentState, args);

    case "bg":
      return parseBackground(currentState, args);

    case "bga":
      return parseBackgroundAlpha(currentState, args);

    case "bl":
    case "blur":
      return parseNonNegativeNumericOption(currentState, args, (value) => ({
        blurEnabled: value > 0,
        blur: value > 0 ? value : defaultFiddleState.blur,
      }));

    case "sh":
    case "sharpen":
      return parseNonNegativeNumericOption(currentState, args, (value) => ({
        sharpenEnabled: value > 0,
        sharpen: value > 0 ? value : defaultFiddleState.sharpen,
      }));

    case "pix":
    case "pixelate":
      return parseNonNegativeIntegerOption(currentState, args, (value) => ({
        pixelateEnabled: value > 1,
        pixelate: value > 1 ? value : defaultFiddleState.pixelate,
      }));

    case "mc":
    case "monochrome":
      return parseMonochrome(currentState, args);

    case "dt":
    case "duotone":
      return parseDuotone(currentState, args);

    case "br":
    case "brightness":
      return parseAdjustmentOption(currentState, args, (value) => ({
        brightnessEnabled: value !== 0,
        brightness: value !== 0 ? value : defaultFiddleState.brightness,
      }));

    case "co":
    case "contrast":
      return parseAdjustmentOption(currentState, args, (value) => ({
        contrastEnabled: value !== 1,
        contrast: value !== 1 ? value : defaultFiddleState.contrast,
      }));

    case "sa":
    case "saturation":
      return parseAdjustmentOption(currentState, args, (value) => ({
        saturationEnabled: value !== 1,
        saturation: value !== 1 ? value : defaultFiddleState.saturation,
      }));

    case "col":
    case "colorize":
      return parseColorize(currentState, args);

    case "gr":
    case "gradient":
      return parseGradient(currentState, args);

    case "g":
      return parseGravity(currentState, args);

    case "f":
      return parseFormat(currentState, args);

    case "q":
      return parseQuality(currentState, args);

    case "autoquality":
    case "aq":
      return parseAutoquality(currentState, args);

    case "max_bytes":
    case "mb":
      return parseMaxBytes(currentState, args);

    case "sm":
      return parseStripMetadata(currentState, args);

    case "kcr":
      return parseKeepCopyright(currentState, args);

    case "scp":
      return parseStripColorProfile(currentState, args);

    case "cp":
    case "icc":
      return parseColorProfile(currentState, args);

    case "ph":
      return parsePreserveHdr(currentState, args);

    default:
      return null;
  }
}

function parseAutoRotate(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1 || args[0] !== "1") {
    return null;
  }

  return { ...currentState, autoRotateEnabled: true };
}

function parseTrim(currentState: FiddleState, args: string[]): FiddleState | null {
  // trim:%threshold[:%color[:%equal_hor[:%equal_ver]]]
  // threshold is required; color, equal_hor, equal_ver are optional.
  if (args.length < 1 || args.length > 4) {
    return null;
  }

  const threshold = parseNumber(args[0]);

  if (threshold === null || threshold < 0) {
    return null;
  }

  const colorArg = args[1] ?? "";
  const ehArg = args[2];
  const evArg = args[3];

  let trimBackgroundMode: TrimBackgroundMode = "auto";
  let trimColor = defaultFiddleState.trimColor;

  if (colorArg !== "") {
    const parsed = hexColor(colorArg);

    if (parsed === null) {
      return null;
    }

    trimBackgroundMode = "color";
    trimColor = parsed;
  }

  const trimEqualHor = ehArg === "1";
  const trimEqualVer = evArg === "1";

  if (ehArg !== undefined && ehArg !== "0" && ehArg !== "1") {
    return null;
  }

  if (evArg !== undefined && evArg !== "0" && evArg !== "1") {
    return null;
  }

  return {
    ...currentState,
    trimEnabled: true,
    trimThreshold: threshold,
    trimBackgroundMode,
    trimColor,
    trimEqualHor,
    trimEqualVer,
  };
}

function parseFlip(currentState: FiddleState, args: string[]): FiddleState | null {
  const flip = flipFromArgs(args);

  if (flip === null) {
    return null;
  }

  return { ...currentState, flip };
}

function flipFromArgs(args: string[]): Flip | null {
  if (args.length === 0) {
    return "both";
  }

  if (args.length === 1 && args[0] === "1") {
    return "horizontal";
  }

  if (args.length === 2 && args[0] === "0" && args[1] === "1") {
    return "vertical";
  }

  return null;
}

function parseRotate(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const rotate = parseNumber(args[0]);

  if (rotate === null || !rotations.has(rotate)) {
    return null;
  }

  return { ...currentState, rotate: rotate as Rotate };
}

function parseCrop(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length < 2 || args.length > 4) {
    return null;
  }

  const [widthArg, heightArg, ...gravityArgs] = args as [string, string, ...string[]];
  const width = parseCropDimension(widthArg);
  const height = parseCropDimension(heightArg);
  const gravity = cropGravityFromArgs(gravityArgs);

  if (width === null || height === null || gravity === null) {
    return null;
  }

  return {
    ...currentState,
    cropEnabled: true,
    cropWidthUnit: width.unit,
    cropWidth: width.unit === "px" ? width.value : currentState.cropWidth,
    cropWidthPercent: width.unit === "percent" ? width.value : currentState.cropWidthPercent,
    cropHeightUnit: height.unit,
    cropHeight: height.unit === "px" ? height.value : currentState.cropHeight,
    cropHeightPercent: height.unit === "percent" ? height.value : currentState.cropHeightPercent,
    cropGravity: gravity,
  };
}

function parseCropAspectRatio(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length < 1 || args.length > 2) {
    return null;
  }

  const ratio = parseNumber(args[0]);

  if (ratio === null || ratio < 0) {
    return null;
  }

  const enlargeArg = args[1];
  const enlarge = enlargeArg === "1" || enlargeArg === "t" || enlargeArg === "true";

  if (
    enlargeArg !== undefined &&
    !enlarge &&
    enlargeArg !== "0" &&
    enlargeArg !== "f" &&
    enlargeArg !== "false"
  ) {
    return null;
  }

  return {
    ...currentState,
    cropAspectRatioEnabled: true,
    cropAspectRatio: ratio,
    cropAspectRatioEnlarge: enlarge,
  };
}

function parseCropDimension(value: string): ParsedDimension<CropDimensionUnit> | null {
  const number = parseNumber(value);

  if (number === null || number < 0) {
    return null;
  }

  if (number === 0) {
    return { unit: "full", value: 0 };
  }

  if (number < 1) {
    return { unit: "percent", value: number * 100 };
  }

  return { unit: "px", value: number };
}

function parseResize(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length < 4 || args.length > 5) {
    return null;
  }

  const [mode, widthArg, heightArg, enlargeArg, extendArg] = args as [
    string,
    string,
    string,
    string,
    string?,
  ];
  const width = parseResizeDimension(widthArg);
  const height = parseResizeDimension(heightArg);

  if (
    !resizeModes.has(mode) ||
    width === null ||
    height === null ||
    !isBooleanArg(enlargeArg) ||
    (extendArg !== undefined && !isBooleanArg(extendArg))
  ) {
    return null;
  }

  return {
    ...currentState,
    resizeEnabled: true,
    resizeMode: mode as ResizeMode,
    resizeWidthUnit: width.unit,
    width: width.unit === "px" ? width.value : currentState.width,
    resizeHeightUnit: height.unit,
    height: height.unit === "px" ? height.value : currentState.height,
    enlarge: enlargeArg === "1",
    resizeExtendEnabled: extendArg === "1",
  };
}

function parseResizeDimension(value: string): ParsedDimension<ResizeDimensionUnit> | null {
  const number = parseNumber(value);

  if (number === null || number < 0) {
    return null;
  }

  if (number === 0) {
    return { unit: "auto", value: 0 };
  }

  return { unit: "px", value: number };
}

function parseNumericOption(
  currentState: FiddleState,
  args: string[],
  buildPatch: (value: number) => Partial<FiddleState>,
): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseNumber(args[0]);

  if (value === null) {
    return null;
  }

  return { ...currentState, ...buildPatch(value) };
}

function parseNonNegativeNumericOption(
  currentState: FiddleState,
  args: string[],
  buildPatch: (value: number) => Partial<FiddleState>,
): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseNumber(args[0]);

  if (value === null || value < 0) {
    return null;
  }

  return { ...currentState, ...buildPatch(value) };
}

function parseNonNegativeIntegerOption(
  currentState: FiddleState,
  args: string[],
  buildPatch: (value: number) => Partial<FiddleState>,
): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseNumber(args[0]);

  if (value === null || !Number.isInteger(value) || value < 0) {
    return null;
  }

  return { ...currentState, ...buildPatch(value) };
}

function parseAdjustmentOption(
  currentState: FiddleState,
  args: string[],
  buildPatch: (value: number) => Partial<FiddleState>,
): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseNumber(args[0]);

  if (value === null) {
    return null;
  }

  return { ...currentState, ...buildPatch(value) };
}

function parseMonochrome(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1 && args.length !== 2) {
    return null;
  }

  const intensity = parseIntensity(args[0]);

  if (intensity === null) {
    return null;
  }

  const color = args[1] === undefined ? defaultFiddleState.monochromeColor : hexColor(args[1]);

  if (color === null) {
    return null;
  }

  return {
    ...currentState,
    monochromeEnabled: intensity > 0,
    monochromeIntensity: intensity > 0 ? intensity : defaultFiddleState.monochromeIntensity,
    monochromeColor: color,
  };
}

function parseDuotone(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length < 1 || args.length > 3) {
    return null;
  }

  const intensity = parseIntensity(args[0]);

  if (intensity === null) {
    return null;
  }

  const shadow =
    args[1] === undefined || args[1] === "" ? defaultFiddleState.duotoneShadow : hexColor(args[1]);
  const highlight =
    args[2] === undefined || args[2] === ""
      ? defaultFiddleState.duotoneHighlight
      : hexColor(args[2]);

  if (shadow === null || highlight === null) {
    return null;
  }

  return {
    ...currentState,
    duotoneEnabled: intensity > 0,
    duotoneIntensity: intensity > 0 ? intensity : defaultFiddleState.duotoneIntensity,
    duotoneShadow: shadow,
    duotoneHighlight: highlight,
  };
}

function parseColorize(currentState: FiddleState, args: string[]): FiddleState | null {
  // col:%opacity:%color[:%keep_alpha]
  if (args.length < 2 || args.length > 3) {
    return null;
  }

  const opacity = parseIntensity(args[0]);
  const color = args[1] === undefined ? null : hexColor(args[1]);

  if (opacity === null || color === null) {
    return null;
  }

  const keepAlphaArg = args[2];
  const keepAlpha = keepAlphaArg === undefined ? false : parseBooleanValue(keepAlphaArg);

  if (keepAlpha === null) {
    return null;
  }

  return {
    ...currentState,
    colorizeEnabled: true,
    colorizeOpacity: opacity,
    colorizeColor: color,
    colorizeKeepAlpha: keepAlpha,
  };
}

function parseGradient(currentState: FiddleState, args: string[]): FiddleState | null {
  // gr:%opacity:%color[:%direction[:%start[:%stop]]]
  if (args.length < 2 || args.length > 5) {
    return null;
  }

  const opacity = parseIntensity(args[0]);
  const color = args[1] === undefined ? null : hexColor(args[1]);

  if (opacity === null || color === null) {
    return null;
  }

  const direction =
    args[2] === undefined || args[2] === "" ? defaultFiddleState.gradientDirection : args[2];

  const start =
    args[3] === undefined || args[3] === "" ? defaultFiddleState.gradientStart : parseUnit(args[3]);
  const stop =
    args[4] === undefined || args[4] === "" ? defaultFiddleState.gradientStop : parseUnit(args[4]);

  if (start === null || stop === null) {
    return null;
  }

  return {
    ...currentState,
    gradientEnabled: true,
    gradientOpacity: opacity,
    gradientColor: color,
    gradientDirection: direction,
    gradientStart: start,
    gradientStop: stop,
  };
}

function parseUnit(value: string | undefined): number | null {
  const number = parseNumber(value);

  if (number === null || number < 0 || number > 1) {
    return null;
  }

  return number;
}

function parseIntensity(value: string | undefined): number | null {
  if (value === undefined) {
    return null;
  }

  const intensity = parseNumber(value);

  if (intensity === null || intensity < 0 || intensity > 1) {
    return null;
  }

  return intensity;
}

function hexColor(value: string): string | null {
  if (!/^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(value)) {
    return null;
  }

  return `#${value.toLowerCase()}`;
}

function parseAspectCanvas(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length < 1 || args.length > 2) {
    return null;
  }

  const enabled = args[0] === "1" || args[0] === "t" || args[0] === "true";
  const disabled = args[0] === "0" || args[0] === "f" || args[0] === "false";

  if (!enabled && !disabled) {
    return null;
  }

  const gravityArg = args[1];

  if (gravityArg !== undefined && !isGravity(gravityArg)) {
    return null;
  }

  return {
    ...currentState,
    aspectCanvasEnabled: enabled,
    aspectCanvasGravity: gravityArg !== undefined ? (gravityArg as Gravity) : "ce",
  };
}

function parsePadding(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 4) {
    return null;
  }

  const [topArg, rightArg, bottomArg, leftArg] = args as [string, string, string, string];
  const top = parseNumber(topArg);
  const right = parseNumber(rightArg);
  const bottom = parseNumber(bottomArg);
  const left = parseNumber(leftArg);

  if (top === null || right === null || bottom === null || left === null) {
    return null;
  }

  return {
    ...currentState,
    paddingEnabled: true,
    paddingTop: top,
    paddingRight: right,
    paddingBottom: bottom,
    paddingLeft: left,
  };
}

function parseBackground(currentState: FiddleState, args: string[]): FiddleState | null {
  const [color] = args as [string?];

  if (args.length !== 1 || color === undefined || !/^[\da-f]{6}$/i.test(color)) {
    return null;
  }

  return {
    ...currentState,
    backgroundEnabled: true,
    backgroundColor: `#${color.toLowerCase()}`,
  };
}

function parseBackgroundAlpha(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const alpha = parseNumber(args[0]);

  if (alpha === null || alpha < 0 || alpha > 1) {
    return null;
  }

  return {
    ...currentState,
    backgroundEnabled: true,
    backgroundAlpha: alpha,
  };
}

function parseGravity(currentState: FiddleState, args: string[]): FiddleState | null {
  const [modeOrGravity, xArg, yArg] = args as [string?, string?, string?];

  if (args.length === 1 && modeOrGravity === "sm") {
    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "smart",
    };
  }

  if (args.length === 1 && modeOrGravity === "obj") {
    // g:obj — bare object gravity (all classes)
    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple" as ObjSubMode,
      objSelectedClasses: [],
    };
  }

  // g:objw:%c1:%w1:…:%cN:%wN — per-class weighted object gravity
  if (args.length >= 2 && modeOrGravity === "objw") {
    const pairs = args.slice(1);
    const weights = parseObjWeightPairs(pairs);

    if (weights === null) {
      return null;
    }

    // Keep only fiddle-offered classes plus "all". Unknown classes are silently
    // dropped (acceptable fiddle limitation per spec).
    const fiddleClasses = new Set(["all", ...fiddleObjClasses]);
    const selectedClasses = Object.keys(weights).filter((cls) => fiddleClasses.has(cls));

    if (selectedClasses.length === 0) {
      return currentState;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted" as ObjSubMode,
      objSelectedClasses: selectedClasses,
      objWeights: Object.fromEntries(selectedClasses.map((cls) => [cls, weights[cls] ?? 1])),
    };
  }

  if (args.length >= 2 && modeOrGravity === "obj") {
    const classes = args.slice(1);

    // g:obj:face is preserved as the legacy objFace mode for UI clarity
    if (classes.length === 1 && classes[0] === "face") {
      return {
        ...currentState,
        gravityEnabled: true,
        gravityMode: "objFace",
      };
    }

    // g:obj:all — "all" as the only token means all objects; normalize to empty
    if (classes.length === 1 && classes[0] === "all") {
      return {
        ...currentState,
        gravityEnabled: true,
        gravityMode: "object",
        objSubMode: "simple" as ObjSubMode,
        objSelectedClasses: [],
      };
    }

    // g:obj:%c…:all — "all" mixed with classes: all is not a COCO class so it
    // gets filtered out below; remaining known classes are kept.

    // g:obj:%c1:…:%cN — explicit class list. Keep only fiddle-offered classes
    // (deduped). If every token is unknown the picker can't represent it, so
    // leave gravity unchanged.
    const knownClasses = [...new Set(classes.filter((cls) => fiddleObjClassSet.has(cls)))];

    if (knownClasses.length === 0) {
      return currentState;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple" as ObjSubMode,
      objSelectedClasses: knownClasses,
    };
  }

  if (args.length === 1 && modeOrGravity !== undefined && isGravity(modeOrGravity)) {
    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "anchor",
      gravity: modeOrGravity,
    };
  }

  if (args.length === 3 && modeOrGravity === "fp") {
    const x = parseNumber(xArg);
    const y = parseNumber(yArg);

    if (x === null || y === null || x < 0 || x > 1 || y < 0 || y > 1) {
      return null;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "focalPoint",
      gravityFocalX: x,
      gravityFocalY: y,
    };
  }

  if (args.length === 3 && modeOrGravity !== undefined && isGravity(modeOrGravity)) {
    const x = parseNumber(xArg);
    const y = parseNumber(yArg);

    if (x === null || y === null) {
      return null;
    }

    return {
      ...currentState,
      gravityEnabled: true,
      gravityMode: "offset",
      gravity: modeOrGravity,
      gravityOffsetX: x,
      gravityOffsetY: y,
    };
  }

  return null;
}

function parseFormat(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1 || !outputFormats.has(args[0] ?? "")) {
    return null;
  }

  return {
    ...currentState,
    formatEnabled: true,
    format: args[0] as OutputFormat,
  };
}

function parseQuality(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const quality = parseNumber(args[0]);

  if (quality === null || !Number.isInteger(quality) || quality < 0 || quality > 100) {
    return null;
  }

  return {
    ...currentState,
    qualityEnabled: true,
    quality,
  };
}

function parseStripMetadata(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseBooleanValue(args[0]);

  if (value === null) {
    return null;
  }

  return {
    ...currentState,
    stripMetadata: value,
    keepCopyright: value ? currentState.keepCopyright : false,
  };
}

function parseKeepCopyright(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseBooleanValue(args[0]);

  if (value === null) {
    return null;
  }

  // keep_copyright is only meaningful when metadata is being stripped; clamp it
  // to false otherwise so the parsed state matches the backend normalization,
  // regardless of segment order (e.g. "sm:0/kcr:1").
  return {
    ...currentState,
    keepCopyright: currentState.stripMetadata ? value : false,
  };
}

function parseStripColorProfile(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseBooleanValue(args[0]);

  if (value === null) {
    return null;
  }

  return {
    ...currentState,
    stripColorProfile: value,
  };
}

function parseColorProfile(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const colorProfile = colorProfileAliases.get(args[0] ?? "");

  if (colorProfile === undefined) {
    return null;
  }

  return {
    ...currentState,
    colorProfile,
  };
}

function parsePreserveHdr(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseBooleanValue(args[0]);

  if (value === null) {
    return null;
  }

  return {
    ...currentState,
    preserveHdr: value,
  };
}

// autoquality:none | autoquality:size:%target[:%min[:%max]]
// | autoquality:ssim2:%target[:%min[:%max[:%allowed_error]]]
function parseAutoquality(currentState: FiddleState, args: string[]): FiddleState | null {
  const [method, ...rest] = args as [string?, ...string[]];

  if (method === "none" && rest.length === 0) {
    return { ...currentState, autoqualityMethod: "none" };
  }

  if (method === "size" && rest.length <= 3) {
    const [target, min, max] = rest;
    return {
      ...currentState,
      autoqualityMethod: "size",
      autoqualityTarget: parsePositiveInteger(target) ?? currentState.autoqualityTarget,
      autoqualityMinQuality: parseQualityValue(min) ?? currentState.autoqualityMinQuality,
      autoqualityMaxQuality: parseQualityValue(max) ?? currentState.autoqualityMaxQuality,
    };
  }

  if (method === "ssim2" && rest.length <= 4) {
    const [target, min, max, allowedError] = rest;
    const parsedTarget = parseScoreValue(target);
    return {
      ...currentState,
      autoqualityMethod: "ssim2",
      autoqualityTarget: parsedTarget ?? currentState.autoqualityTarget,
      autoqualityMinQuality: parseQualityValue(min) ?? currentState.autoqualityMinQuality,
      autoqualityMaxQuality: parseQualityValue(max) ?? currentState.autoqualityMaxQuality,
      autoqualityAllowedError:
        parseNonNegativeNumber(allowedError) ?? currentState.autoqualityAllowedError,
    };
  }

  return null;
}

function parseMaxBytes(currentState: FiddleState, args: string[]): FiddleState | null {
  if (args.length !== 1) {
    return null;
  }

  const maxBytes = parsePositiveInteger(args[0]);

  if (maxBytes === null) {
    return null;
  }

  return {
    ...currentState,
    maxBytesEnabled: true,
    maxBytes,
  };
}

function parsePositiveInteger(value: string | undefined): number | null {
  const number = parseNumber(value);

  if (number === null || !Number.isInteger(number) || number <= 0) {
    return null;
  }

  return number;
}

function parseQualityValue(value: string | undefined): number | null {
  const number = parseNumber(value);

  if (number === null || !Number.isInteger(number) || number < 1 || number > 100) {
    return null;
  }

  return number;
}

function parseScoreValue(value: string | undefined): number | null {
  const number = parseNumber(value);

  if (number === null || number < 0 || number > 100) {
    return null;
  }

  return number;
}

function parseNonNegativeNumber(value: string | undefined): number | null {
  const number = parseNumber(value);

  if (number === null || number < 0) {
    return null;
  }

  return number;
}

function parseBooleanValue(value: string | undefined): boolean | null {
  if (value === "1" || value === "t" || value === "true") {
    return true;
  }

  if (value === "0" || value === "f" || value === "false") {
    return false;
  }

  return null;
}

function isGravity(value: string): value is Gravity {
  return gravityValues.has(value);
}

function cropGravityFromArgs(args: string[]): CropGravity | null {
  if (args.length === 0) {
    return "inherit";
  }

  if (args.length === 1) {
    const [value] = args as [string];

    if (value === "sm" || isGravity(value)) {
      return value;
    }

    // bare obj gravity: c:W:H:obj
    if (value === "obj") {
      return "obj";
    }

    return null;
  }

  if (args.length === 2 && args[0] === "obj" && args[1] === "face") {
    return "obj:face";
  }

  if (args.length === 2 && args[0] === "obj" && args[1] === "all") {
    return "obj:all";
  }

  return null;
}

function isBooleanArg(value: string): boolean {
  return value === "0" || value === "1";
}

// Parses objw class/weight pairs from URL tokens into a weight record.
// Tokens are positional: class, weight, class, weight, …
// Returns null on odd arity, empty class tokens, or non-positive/non-numeric weights.
function parseObjWeightPairs(tokens: string[]): Record<string, number> | null {
  if (tokens.length === 0 || tokens.length % 2 !== 0) {
    return null;
  }

  const weights: Record<string, number> = {};

  for (let i = 0; i < tokens.length; i += 2) {
    const cls = tokens[i];
    const weightStr = tokens[i + 1];

    if (cls === undefined || cls === "" || weightStr === undefined) {
      return null;
    }

    const weight = parseNumber(weightStr);

    if (weight === null || weight <= 0) {
      return null;
    }

    weights[cls] = weight;
  }

  return weights;
}

function parseNumber(value: string | undefined): number | null {
  if (value === undefined || value.trim() === "") {
    return null;
  }

  const number = Number(value);

  return Number.isFinite(number) ? number : null;
}

export type Provider = "imgproxy" | "iiif" | "twicpics";

export const providers: readonly { id: Provider; label: string }[] = [
  { id: "imgproxy", label: "imgproxy" },
  { id: "iiif", label: "IIIF (Image API 3.0)" },
  { id: "twicpics", label: "TwicPics" },
];

export type AppState = {
  provider: Provider;
  imgproxy: FiddleState;
  iiif: IiifState;
  twicpics: TwicPicsState;
};

export function defaultAppState(): AppState {
  return {
    provider: "imgproxy",
    imgproxy: { ...defaultFiddleState },
    iiif: { ...defaultIiifState },
    twicpics: { ...defaultTwicPicsState },
  };
}

// Builds the browser URL for the ACTIVE provider only. The /imgproxy prefix lives
// here, never in the imgproxy signed-path builder (fiddlePathForState).
export function appPathForState(state: AppState): string {
  if (state.provider === "iiif") {
    return iiifBrowserPath(state.iiif);
  }

  if (state.provider === "twicpics") {
    return twicBrowserPath(state.twicpics);
  }

  return `/imgproxy${fiddlePathForState(state.imgproxy)}`;
}

// Parses a browser URL into an AppState. The inactive slice is defaulted here;
// App.svelte merges to preserve the in-memory inactive slice across popstate.
// Dispatch is on the first path segment.
export function parseAppPath(pathname: string, search = ""): AppState {
  const [, first = "", ...rest] = pathname.split("/");

  if (first === "twicpics") {
    const twicpics = parseTwicTail(rest.join("/"), search);
    return {
      provider: "twicpics",
      imgproxy: { ...defaultFiddleState },
      iiif: { ...defaultIiifState },
      twicpics: twicpics ?? { ...defaultTwicPicsState },
    };
  }

  if (first === "iiif") {
    const iiif = parseIiifTail(rest.join("/"));
    return {
      provider: "iiif",
      imgproxy: { ...defaultFiddleState },
      iiif: iiif ?? { ...defaultIiifState },
      twicpics: { ...defaultTwicPicsState },
    };
  }

  if (first === "imgproxy") {
    return {
      provider: "imgproxy",
      imgproxy: parseFiddlePath("/" + rest.join("/")),
      iiif: { ...defaultIiifState },
      twicpics: { ...defaultTwicPicsState },
    };
  }

  return defaultAppState();
}

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  buildProcessingPath,
  cocoClasses,
  controlLimits,
  cropDimensionSegment,
  cropOptionSegment,
  cropPixelLimit,
  type FiddleState,
  defaultFiddleState,
  debounce,
  focalPointFromBounds,
  gravitySegment,
  imageRequestBytesFromPerformance,
  objGravitySegment,
  objGravitySegmentFromState,
  resetCropPixelsToSource,
  processedSizeLabel,
  optionSegments,
  processingPathFromSignedPath,
  resizeOptionSegment,
  resolvedOutputLabel,
  signProcessingPath,
  signedPathForState,
  trimOptionSegment,
} from "./processing-path";
import {
  fiddlePathForState,
  expandedToolboxesForState,
  parseFiddlePath,
  resetFiddleSettings,
} from "./fiddle-url-state";

const activeFiddleState = {
  ...defaultFiddleState,
  resizeEnabled: true,
  gravityEnabled: true,
  qualityEnabled: true,
};

afterEach(() => {
  vi.useRealTimers();
});

describe("debounce", () => {
  it("runs only the latest scheduled callback after the delay", () => {
    vi.useFakeTimers();

    const calls: string[] = [];
    const schedule = debounce((value: string) => calls.push(value), 150);

    schedule("first");
    vi.advanceTimersByTime(100);
    schedule("second");
    vi.advanceTimersByTime(149);

    expect(calls).toEqual([]);

    vi.advanceTimersByTime(1);

    expect(calls).toEqual(["second"]);
  });
});

describe("processing path generation", () => {
  it("defines shared control limits for slider-backed inputs", () => {
    expect(controlLimits.quality).toEqual({ min: 0, max: 100, step: 1 });
    expect(controlLimits.crop.percent).toEqual({ min: 1, max: 99, step: 1 });
    expect(controlLimits.resize.width).toEqual({ min: 1, max: 1600, step: 1 });
  });

  it("uses the source image dimensions as crop pixel limits", () => {
    expect(cropPixelLimit("images/dog.jpg", "width")).toEqual({ min: 1, max: 5011, step: 1 });
    expect(cropPixelLimit("images/dog.jpg", "height")).toEqual({ min: 1, max: 7516, step: 1 });
    expect(cropPixelLimit("images/beach.jpg", "width")).toEqual({ min: 1, max: 4000, step: 1 });
    expect(cropPixelLimit("images/beach.jpg", "height")).toEqual({ min: 1, max: 2667, step: 1 });
  });

  it("defaults crop pixel dimensions to the default source dimensions", () => {
    expect(defaultFiddleState.cropWidth).toBe(
      cropPixelLimit(defaultFiddleState.source, "width").max,
    );
    expect(defaultFiddleState.cropHeight).toBe(
      cropPixelLimit(defaultFiddleState.source, "height").max,
    );
  });

  it("can reset crop pixel dimensions to the selected source dimensions", () => {
    expect(
      resetCropPixelsToSource({
        ...defaultFiddleState,
        source: "images/beach.jpg",
        cropWidth: 1,
        cropHeight: 1,
      }),
    ).toMatchObject({
      cropWidth: 4000,
      cropHeight: 2667,
    });
  });

  it("builds the default processing path", () => {
    expect(optionSegments(defaultFiddleState)).toEqual([]);
    expect(buildProcessingPath(defaultFiddleState)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("builds a signed request path from a generated signature", () => {
    const state = {
      ...defaultFiddleState,
      signatureMode: "signed" as const,
      resizeEnabled: true,
    };

    expect(signedPathForState(state)).toBe("/rs:fill:640:360:0/plain/local:///images/dog.jpg");
    expect(processingPathFromSignedPath("local-signature", signedPathForState(state))).toBe(
      "/img/local-signature/rs:fill:640:360:0/plain/local:///images/dog.jpg",
    );
  });

  it("generates imgproxy-compatible HMAC signatures", async () => {
    const signature = await signProcessingPath(
      "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png",
      "736563726574",
      "68656c6c6f",
    );

    expect(signature).toBe("oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8");
  });

  it("rejects invalid signature sizes before signing", async () => {
    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 0),
    ).rejects.toThrow(RangeError);

    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 33),
    ).rejects.toThrow("signatureSize must be an integer between 1 and 32");

    await expect(
      signProcessingPath("/plain/local:///images/dog.jpg", "736563726574", "68656c6c6f", 1.5),
    ).rejects.toThrow("signatureSize must be an integer between 1 and 32");
  });

  it("keeps jpeg selected as the default explicit format", () => {
    expect(defaultFiddleState.format).toBe("jpeg");
  });

  it("reads processed byte size from the latest matching resource timing entry", () => {
    const entries = [
      { name: "http://localhost:4000/_/plain/local:///images/dog.jpg", encodedBodySize: 120 },
      { name: "http://localhost:4000/_/plain/local:///images/cat.jpg", encodedBodySize: 90 },
      { name: "http://localhost:4000/_/plain/local:///images/dog.jpg", encodedBodySize: 456 },
    ];

    expect(
      imageRequestBytesFromPerformance(
        "http://localhost:4000/_/plain/local:///images/dog.jpg",
        entries,
      ),
    ).toBe(456);
  });

  it("falls back to decoded resource timing size and ignores unavailable sizes", () => {
    const entries = [
      {
        name: "http://localhost:4000/_/plain/local:///images/dog.jpg",
        encodedBodySize: 0,
        decodedBodySize: 321,
      },
      {
        name: "http://localhost:4000/_/plain/local:///images/dog.jpg",
        encodedBodySize: 0,
        decodedBodySize: 0,
      },
    ];

    expect(
      imageRequestBytesFromPerformance(
        "http://localhost:4000/_/plain/local:///images/dog.jpg",
        entries,
      ),
    ).toBe(321);
  });

  it("includes auto rotate as an explicit orientation option", () => {
    const state = {
      ...defaultFiddleState,
      autoRotateEnabled: true,
    };

    expect(optionSegments(state)).toEqual(["ar:1"]);
    expect(buildProcessingPath(state)).toBe("/img/_/ar:1/plain/local:///images/dog.jpg");
  });

  it("includes flip options for each supported flip axis", () => {
    expect(optionSegments({ ...defaultFiddleState, flip: "horizontal" })).toEqual(["fl:1"]);
    expect(optionSegments({ ...defaultFiddleState, flip: "vertical" })).toEqual(["fl:0:1"]);
    expect(optionSegments({ ...defaultFiddleState, flip: "both" })).toEqual(["fl"]);
  });

  it("includes rotate when a right-angle rotation is selected", () => {
    expect(optionSegments({ ...defaultFiddleState, rotate: 90 })).toEqual(["rot:90"]);
    expect(optionSegments({ ...defaultFiddleState, rotate: 180 })).toEqual(["rot:180"]);
    expect(optionSegments({ ...defaultFiddleState, rotate: 270 })).toEqual(["rot:270"]);
  });

  it("emits nothing for trim when disabled", () => {
    expect(trimOptionSegment(defaultFiddleState)).toBeNull();
    expect(optionSegments(defaultFiddleState)).toEqual([]);
  });

  it("emits trim with threshold only when background is auto and flags are off", () => {
    const state = {
      ...defaultFiddleState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto" as const,
      trimEqualHor: false,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:10");
    expect(optionSegments(state)).toEqual(["trim:10"]);
    expect(buildProcessingPath(state)).toBe("/img/_/trim:10/plain/local:///images/dog.jpg");
  });

  it("emits trim with color when background mode is color", () => {
    const state = {
      ...defaultFiddleState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "color" as const,
      trimColor: "#ff00ff",
      trimEqualHor: false,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:10:ff00ff");
  });

  it("emits trim with empty color slot when auto background but flags are set", () => {
    const state = {
      ...defaultFiddleState,
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto" as const,
      trimEqualHor: true,
      trimEqualVer: true,
    };

    expect(trimOptionSegment(state)).toBe("trim:10::1:1");
  });

  it("emits trim with color and flags", () => {
    const state = {
      ...defaultFiddleState,
      trimEnabled: true,
      trimThreshold: 20,
      trimBackgroundMode: "color" as const,
      trimColor: "#ff00ff",
      trimEqualHor: true,
      trimEqualVer: false,
    };

    expect(trimOptionSegment(state)).toBe("trim:20:ff00ff:1:0");
  });

  it("emits trim before crop in the option segment order", () => {
    const state = {
      ...defaultFiddleState,
      trimEnabled: true,
      trimThreshold: 10,
      cropEnabled: true,
      cropWidth: 320,
      cropHeight: 240,
    };

    const segs = optionSegments(state);
    const trimIdx = segs.findIndex((s) => s.startsWith("trim:"));
    const cropIdx = segs.findIndex((s) => s.startsWith("c:"));

    expect(trimIdx).toBeGreaterThanOrEqual(0);
    expect(cropIdx).toBeGreaterThanOrEqual(0);
    expect(trimIdx).toBeLessThan(cropIdx);
  });

  it("includes resize extend as the resize segment extend argument", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      resizeExtendEnabled: true,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0:1"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0:1/plain/local:///images/dog.jpg",
    );
  });

  it("builds the resize tool summary from the emitted resize segment", () => {
    expect(resizeOptionSegment(defaultFiddleState)).toBeNull();

    expect(resizeOptionSegment({ ...defaultFiddleState, resizeEnabled: true })).toBe(
      "rs:fill:640:360:0",
    );

    expect(
      resizeOptionSegment({
        ...defaultFiddleState,
        resizeEnabled: true,
        resizeWidthUnit: "auto" as const,
        resizeHeightUnit: "px" as const,
        height: 360,
      }),
    ).toBe("rs:fill:0:360:0");
  });

  it("emits resize auto dimensions as zero per axis", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      resizeWidthUnit: "auto" as const,
      resizeHeightUnit: "px" as const,
      height: 360,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:0:360:0"]);
  });

  it("allows both resize dimensions to be auto", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      resizeMode: "force" as const,
      resizeWidthUnit: "auto" as const,
      resizeHeightUnit: "auto" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:force:0:0:0"]);
  });

  it("does not emit resize extend when resize is disabled", () => {
    const state = {
      ...defaultFiddleState,
      resizeExtendEnabled: true,
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("includes extend aspect ratio when aspect canvas is enabled", () => {
    const state = {
      ...defaultFiddleState,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "ce" as const,
    };

    expect(optionSegments(state)).toEqual(["exar:1"]);
    expect(buildProcessingPath(state)).toBe("/img/_/exar:1/plain/local:///images/dog.jpg");
  });

  it("round-trips exar with gravity", () => {
    const state = {
      ...defaultFiddleState,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "no" as const,
    };
    expect(optionSegments(state)).toEqual(["exar:1:no"]);
  });

  it("includes explicit four-sided padding after aspect canvas options", () => {
    const state = {
      ...defaultFiddleState,
      aspectCanvasEnabled: true,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 16,
      paddingBottom: 24,
      paddingLeft: 32,
    };

    expect(optionSegments(state)).toEqual(["exar:1", "pd:8:16:24:32"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/exar:1/pd:8:16:24:32/plain/local:///images/dog.jpg",
    );
  });

  it("includes background color and opacity after padding", () => {
    const state = {
      ...defaultFiddleState,
      paddingEnabled: true,
      paddingTop: 8,
      paddingRight: 8,
      paddingBottom: 8,
      paddingLeft: 8,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.5,
    };

    expect(optionSegments(state)).toEqual(["pd:8:8:8:8", "bg:ffcc00", "bga:0.5"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/pd:8:8:8:8/bg:ffcc00/bga:0.5/plain/local:///images/dog.jpg",
    );
  });

  it("includes basic effects after background options", () => {
    const state = {
      ...defaultFiddleState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      blurEnabled: true,
      blur: 2.5,
      sharpenEnabled: true,
      sharpen: 0.7,
      pixelateEnabled: true,
      pixelate: 8,
      monochromeEnabled: true,
      monochromeIntensity: 0.5,
      monochromeColor: "#ffcc00",
      duotoneEnabled: true,
      duotoneIntensity: 0.25,
      duotoneShadow: "#112233",
      duotoneHighlight: "#ffeecc",
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: 1.4,
      saturationEnabled: true,
      saturation: 0.7,
    };

    expect(optionSegments(state)).toEqual([
      "bg:ffcc00",
      "bl:2.5",
      "sh:0.7",
      "pix:8",
      "mc:0.5:ffcc00",
      "dt:0.25:112233:ffeecc",
      "br:20",
      "co:1.4",
      "sa:0.7",
    ]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/bg:ffcc00/bl:2.5/sh:0.7/pix:8/mc:0.5:ffcc00/dt:0.25:112233:ffeecc/br:20/co:1.4/sa:0.7/plain/local:///images/dog.jpg",
    );
  });

  it("includes colorize and gradient after the adjustment effects", () => {
    const state = {
      ...defaultFiddleState,
      colorizeEnabled: true,
      colorizeOpacity: 0.5,
      colorizeColor: "#ff0000",
      colorizeKeepAlpha: true,
      gradientEnabled: true,
      gradientOpacity: 0.6,
      gradientColor: "#000000",
      gradientDirection: "down",
      gradientStart: 0,
      gradientStop: 1,
    };

    expect(optionSegments(state)).toEqual(["col:0.5:ff0000:1", "gr:0.6:000000:down:0:1"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/col:0.5:ff0000:1/gr:0.6:000000:down:0:1/plain/local:///images/dog.jpg",
    );
  });

  it("omits background alpha when opacity is full", () => {
    const state = {
      ...defaultFiddleState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 1,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00"]);
    expect(buildProcessingPath(state)).toBe("/img/_/bg:ffcc00/plain/local:///images/dog.jpg");
  });

  it("preserves custom background opacity decimals", () => {
    const state = {
      ...defaultFiddleState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.42,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00", "bga:0.42"]);
  });

  it("allows fully transparent background opacity", () => {
    const state = {
      ...defaultFiddleState,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0,
    };

    expect(optionSegments(state)).toEqual(["bg:ffcc00", "bga:0"]);
  });

  it("includes crop options before resize options when crop is enabled", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropWidth: 320,
      cropHeight: 240,
    };

    expect(optionSegments(state)).toEqual(["c:320:240", "rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("does not write inherited crop gravity into the crop segment", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "inherit" as const,
      gravity: "nowe" as const,
    };

    expect(optionSegments(state)).toEqual(["c:5011:7516", "rs:fill:640:360:0", "g:nowe", "q:85"]);
  });

  it("uses shared gravity as the top-level gravity option", () => {
    const state = {
      ...activeFiddleState,
      gravity: "sowe" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:sowe", "q:85"]);
  });

  it("includes focal point global gravity", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.25,
      gravityFocalY: 0.75,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:fp:0.25:0.75"]);
  });

  it("includes focal point global gravity without requiring resize or crop", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.25,
      gravityFocalY: 0.75,
    };

    expect(optionSegments(state)).toEqual(["g:fp:0.25:0.75"]);
    expect(fiddlePathForState(state)).toBe("/g:fp:0.25:0.75/plain/local:///images/dog.jpg");
  });

  it("includes offset global gravity", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "offset" as const,
      gravity: "soea" as const,
      gravityOffsetX: 12,
      gravityOffsetY: -0.25,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:soea:12:-0.25"]);
  });

  it("includes smart global gravity without offsets", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "smart" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:sm"]);
  });

  it("round-trips smart global gravity through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:sm/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "smart",
    });

    expect(fiddlePathForState(parsed)).toBe("/g:sm/plain/local:///images/dog.jpg");
  });

  it("round-trips smart crop gravity through the fiddle path", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "sm" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:sm");

    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "sm",
    });
  });

  it("includes object (face) global gravity without offsets", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      gravityEnabled: true,
      gravityMode: "objFace" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:obj:face"]);
  });

  it("round-trips object (face) global gravity through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:obj:face/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "objFace",
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj:face/plain/local:///images/dog.jpg");
  });

  it("round-trips object (face) crop gravity through the fiddle path", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "obj:face" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj:face");

    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj:face",
    });
  });

  // ---- Object gravity: Simple sub-mode ----

  it("emits bare g:obj for object gravity with no classes selected (simple)", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "simple" as const,
      objSelectedClasses: [],
    };

    expect(optionSegments(state)).toEqual(["g:obj"]);
  });

  it("emits g:obj:car:dog for simple mode with two classes (sorted)", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "simple" as const,
      objSelectedClasses: ["dog", "car"],
    };

    // sorted: car before dog
    expect(optionSegments(state)).toEqual(["g:obj:car:dog"]);
  });

  it("round-trips bare g:obj through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:obj/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: [],
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj/plain/local:///images/dog.jpg");
  });

  it("normalizes g:obj:all to bare g:obj (empty selection = all objects)", () => {
    const parsed = parseFiddlePath("/g:obj:all/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: [],
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj/plain/local:///images/dog.jpg");
  });

  it("round-trips g:obj with explicit classes through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:obj:car:dog/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "simple",
      objSelectedClasses: expect.arrayContaining(["car", "dog"]),
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj:car:dog/plain/local:///images/dog.jpg");
  });

  it("drops class tokens not offered in the fiddle UI, keeping only fiddle-offered classes", () => {
    // 'car' is a fiddle class; 'spaceship' is not
    const parsed = parseFiddlePath("/g:obj:car:spaceship/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSelectedClasses: ["car"],
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj:car/plain/local:///images/dog.jpg");
  });

  it("leaves gravity unchanged for an all-unknown g:obj segment", () => {
    const parsed = parseFiddlePath("/g:obj:spaceship/plain/local:///images/dog.jpg");

    // every token unknown -> the picker can't represent it, gravity is unchanged
    expect(parsed.gravityMode).not.toBe("object");
  });

  it("g:obj:car:all — 'all' mixed with classes falls through to known-class filter", () => {
    // 'all' is not in fiddleObjClassSet so it gets dropped; 'car' is kept
    const parsed = parseFiddlePath("/g:obj:car:all/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSelectedClasses: ["car"],
    });

    expect(fiddlePathForState(parsed)).toBe("/g:obj:car/plain/local:///images/dog.jpg");
  });

  it("preserves g:obj:face as the legacy objFace mode", () => {
    const parsed = parseFiddlePath("/g:obj:face/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "objFace",
    });
  });

  it("round-trips bare crop obj gravity through the fiddle path", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "obj" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj");

    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj",
    });
  });

  it("round-trips explicit obj:all crop gravity through the fiddle path", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "obj:all" as const,
    };

    const segments = optionSegments(state);
    expect(segments).toContain("c:5011:7516:obj:all");

    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed).toMatchObject({
      cropEnabled: true,
      cropGravity: "obj:all",
    });
  });

  it("objGravitySegment helper produces correct URL segments", () => {
    expect(objGravitySegment([])).toBe("g:obj");
    expect(objGravitySegment(["car"])).toBe("g:obj:car");
    expect(objGravitySegment(["car", "dog"])).toBe("g:obj:car:dog");
  });

  // ---- Object gravity: Weighted sub-mode ----

  it("weighted mode with empty selection emits bare g:obj", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "weighted" as const,
      objSelectedClasses: [],
      objWeights: {},
    };

    expect(optionSegments(state)).toEqual(["g:obj"]);
  });

  it("weighted mode with all-equal weights emits compact g:obj form", () => {
    // car=1, dog=1 — uniform, inert → compact g:obj:car:dog
    expect(
      objGravitySegmentFromState({
        ...defaultFiddleState,
        objSubMode: "weighted",
        objSelectedClasses: ["car", "dog"],
        objWeights: { car: 1, dog: 1 },
      }),
    ).toBe("g:obj:car:dog");

    // single class, any weight → uniform, compact form
    expect(
      objGravitySegmentFromState({
        ...defaultFiddleState,
        objSubMode: "weighted",
        objSelectedClasses: ["car"],
        objWeights: { car: 2 },
      }),
    ).toBe("g:obj:car");
  });

  it("weighted mode with non-uniform weights emits g:objw verbatim (class:1 kept)", () => {
    // car=1, dog=2 — not uniform, car:1 must NOT be dropped
    expect(
      objGravitySegmentFromState({
        ...defaultFiddleState,
        objSubMode: "weighted",
        objSelectedClasses: ["car", "dog"],
        objWeights: { car: 1, dog: 2 },
      }),
    ).toBe("g:objw:car:1:dog:2");
  });

  it("weighted mode with all=2 and face=3 emits g:objw:all:2:face:3", () => {
    expect(
      objGravitySegmentFromState({
        ...defaultFiddleState,
        objSubMode: "weighted",
        objSelectedClasses: ["all", "face"],
        objWeights: { all: 2, face: 3 },
      }),
    ).toBe("g:objw:all:2:face:3");
  });

  it("g:objw:all:1:face:3 preserves both classes (NOT normalized — different semantics)", () => {
    // g:objw:all:1:face:3 detects ALL objects with face boosted 3×.
    // g:objw:face:3 filters to face only.
    // These are DIFFERENT requests — the fiddle must NOT rewrite one into the other.
    const parsed = parseFiddlePath("/g:objw:all:1:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityMode: "object",
      objSubMode: "weighted",
      objSelectedClasses: expect.arrayContaining(["all", "face"]),
      objWeights: expect.objectContaining({ all: 1, face: 3 }),
    });

    // Serializes back with both all and face (uniform weights → compact obj form,
    // but all:1 face:3 are NOT uniform so → objw verbatim)
    expect(fiddlePathForState(parsed)).toBe("/g:objw:all:1:face:3/plain/local:///images/dog.jpg");
  });

  it("round-trips g:objw:face:3 (single face weight) through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:objw:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted",
      objSelectedClasses: ["face"],
      objWeights: { face: 3 },
    });

    // Single class with weight 3 → uniform (only one) → compact g:obj:face form
    expect(fiddlePathForState(parsed)).toBe("/g:obj:face/plain/local:///images/dog.jpg");
  });

  it("round-trips g:objw:all:2:face:3 through the fiddle path", () => {
    const parsed = parseFiddlePath("/g:objw:all:2:face:3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted",
      objWeights: expect.objectContaining({ all: 2, face: 3 }),
    });

    expect(fiddlePathForState(parsed)).toBe("/g:objw:all:2:face:3/plain/local:///images/dog.jpg");
  });

  it("emits g:objw for object gravity with non-uniform weighted mode", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "object" as const,
      objSubMode: "weighted" as const,
      objSelectedClasses: ["face", "person"],
      objWeights: { face: 3, person: 1 },
    };

    expect(optionSegments(state)).toEqual(["g:objw:face:3:person:1"]);
    expect(fiddlePathForState(state)).toBe("/g:objw:face:3:person:1/plain/local:///images/dog.jpg");
  });

  it("rejects invalid objw gravity values in fiddle routes", () => {
    // bare g:objw (no pairs)
    expect(parseFiddlePath("/g:objw/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    // odd arity
    expect(parseFiddlePath("/g:objw:face/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    // non-positive weight
    expect(parseFiddlePath("/g:objw:face:0/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/g:objw:face:-2/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    // non-numeric weight
    expect(parseFiddlePath("/g:objw:face:bad/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("COCO-80 class list has exactly 80 entries in underscore spelling", () => {
    expect(cocoClasses).toHaveLength(80);
    expect(cocoClasses).toContain("person");
    expect(cocoClasses).toContain("traffic_light");
    expect(cocoClasses).toContain("toothbrush");
    // No space-spelled entries
    expect(cocoClasses.every((c) => !c.includes(" "))).toBe(true);
  });

  it("normalizes focal point coordinates from a picker rectangle", () => {
    expect(
      focalPointFromBounds(150, 75, {
        left: 100,
        top: 50,
        width: 200,
        height: 100,
      }),
    ).toEqual({ x: 0.25, y: 0.25 });
  });

  it("clamps focal point coordinates to the picker rectangle", () => {
    expect(
      focalPointFromBounds(360, 20, {
        left: 100,
        top: 50,
        width: 200,
        height: 100,
      }),
    ).toEqual({ x: 1, y: 0 });
  });

  it("keeps focal point coordinates stable for an unloaded picker rectangle", () => {
    expect(
      focalPointFromBounds(100, 50, {
        left: 100,
        top: 50,
        width: 0,
        height: 0,
      }),
    ).toEqual({ x: 0, y: 0 });
  });

  it("allows crop to use an explicit gravity", () => {
    const state = {
      ...activeFiddleState,
      cropEnabled: true,
      cropGravity: "soea" as const,
      gravity: "ce" as const,
    };

    expect(optionSegments(state)).toEqual([
      "c:5011:7516:soea",
      "rs:fill:640:360:0",
      "g:ce",
      "q:85",
    ]);
  });

  it("builds the crop tool summary from the emitted crop segment", () => {
    expect(cropOptionSegment(defaultFiddleState)).toBeNull();

    expect(cropOptionSegment({ ...defaultFiddleState, cropEnabled: true })).toBe("c:5011:7516");

    expect(
      cropOptionSegment({
        ...defaultFiddleState,
        cropEnabled: true,
        cropWidthUnit: "percent" as const,
        cropWidthPercent: 50,
        cropHeightUnit: "full" as const,
        cropGravity: "soea" as const,
      }),
    ).toBe("c:0.5:0:soea");
  });

  it("emits mixed relative and pixel crop dimensions", () => {
    const state = {
      ...defaultFiddleState,
      cropEnabled: true,
      cropWidthUnit: "percent" as const,
      cropWidthPercent: 50,
      cropHeightUnit: "px" as const,
      cropHeight: 240,
    };

    expect(optionSegments(state)).toEqual(["c:0.5:240"]);
  });

  it("emits full crop dimensions as zero per axis", () => {
    const state = {
      ...defaultFiddleState,
      cropEnabled: true,
      cropWidthUnit: "full" as const,
      cropHeightUnit: "percent" as const,
      cropHeightPercent: 25,
    };

    expect(optionSegments(state)).toEqual(["c:0:0.25"]);
  });

  it("keeps crop zero exclusive to the full unit", () => {
    expect(cropDimensionSegment("px", 0, 50)).toBe("1");
    expect(cropDimensionSegment("full", 320, 50)).toBe("0");
  });

  it("includes enabled resize extras after the resize segment", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      zoomEnabled: true,
      zoom: 1.5,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 180,
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "z:1.5",
      "dpr:2",
      "mw:320",
      "mh:180",
    ]);
  });

  it("includes enabled resize extras even when resize is disabled", () => {
    const state = {
      ...defaultFiddleState,
      zoomEnabled: true,
      zoom: 1.5,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 180,
    };

    expect(optionSegments(state)).toEqual(["z:1.5", "dpr:2", "mw:320", "mh:180"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/z:1.5/dpr:2/mw:320/mh:180/plain/local:///images/dog.jpg",
    );
  });

  it("omits explicit format when format is disabled", () => {
    const state = {
      ...activeFiddleState,
      formatEnabled: false,
      format: "png" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("includes explicit format when format is enabled", () => {
    const state = {
      ...activeFiddleState,
      formatEnabled: true,
      format: "png" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "f:png", "q:85"]);
  });

  it("omits quality when quality is disabled", () => {
    const state = {
      ...activeFiddleState,
      qualityEnabled: false,
      quality: 42,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/g:ce/plain/local:///images/dog.jpg",
    );
  });

  it("includes zero quality when quality is enabled", () => {
    const state = {
      ...activeFiddleState,
      qualityEnabled: true,
      quality: 0,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:0"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/g:ce/q:0/plain/local:///images/dog.jpg",
    );
  });

  it("omits autoquality when the method is none", () => {
    const state = {
      ...activeFiddleState,
      autoqualityMethod: "none" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("defaults each autoquality target within its own valid range", () => {
    expect(defaultFiddleState.autoqualitySizeTarget).toBeGreaterThanOrEqual(
      controlLimits.autoquality.sizeTarget.min,
    );
    expect(defaultFiddleState.autoqualitySizeTarget).toBeLessThanOrEqual(
      controlLimits.autoquality.sizeTarget.max,
    );
    expect(defaultFiddleState.autoqualitySsim2Target).toBeGreaterThanOrEqual(
      controlLimits.autoquality.ssim2Target.min,
    );
    expect(defaultFiddleState.autoqualitySsim2Target).toBeLessThanOrEqual(
      controlLimits.autoquality.ssim2Target.max,
    );
  });

  it("serializes size autoquality as target:min:max", () => {
    const state = {
      ...activeFiddleState,
      autoqualityMethod: "size" as const,
      autoqualitySizeTarget: 40000,
      autoqualityMinQuality: 60,
      autoqualityMaxQuality: 90,
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "g:ce",
      "q:85",
      "autoquality:size:40000:60:90",
    ]);
  });

  it("serializes ssim2 autoquality with the allowed_error field", () => {
    const state = {
      ...activeFiddleState,
      autoqualityMethod: "ssim2" as const,
      autoqualitySsim2Target: 80,
      autoqualityMinQuality: 50,
      autoqualityMaxQuality: 95,
      autoqualityAllowedError: 1.5,
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "g:ce",
      "q:85",
      "autoquality:ssim2:80:50:95:1.5",
    ]);
  });

  it("serializes butteraugli autoquality with the allowed_error field", () => {
    const state = {
      ...activeFiddleState,
      autoqualityMethod: "butteraugli" as const,
      autoqualityButteraugliTarget: 1,
      autoqualityMinQuality: 50,
      autoqualityMaxQuality: 95,
      autoqualityAllowedError: 0.1,
    };

    expect(optionSegments(state)).toEqual([
      "rs:fill:640:360:0",
      "g:ce",
      "q:85",
      "autoquality:butteraugli:1:50:95:0.1",
    ]);
  });

  it("omits max bytes when disabled or zero", () => {
    const disabled = { ...activeFiddleState, maxBytesEnabled: false, maxBytes: 50000 };
    const zero = { ...activeFiddleState, maxBytesEnabled: true, maxBytes: 0 };

    expect(optionSegments(disabled)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
    expect(optionSegments(zero)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85"]);
  });

  it("serializes max bytes as mb:%n when enabled", () => {
    const state = { ...activeFiddleState, maxBytesEnabled: true, maxBytes: 75000 };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "g:ce", "q:85", "mb:75000"]);
  });

  it("omits top-level gravity when gravity is disabled", () => {
    const state = {
      ...activeFiddleState,
      gravityEnabled: false,
      gravity: "sowe" as const,
    };

    expect(optionSegments(state)).toEqual(["rs:fill:640:360:0", "q:85"]);
    expect(buildProcessingPath(state)).toBe(
      "/img/_/rs:fill:640:360:0/q:85/plain/local:///images/dog.jpg",
    );
  });

  it("keeps global gravity when resize is disabled", () => {
    const state = {
      ...activeFiddleState,
      resizeEnabled: false,
    };

    expect(optionSegments(state)).toEqual(["g:ce", "q:85"]);
    expect(buildProcessingPath(state)).toBe("/img/_/g:ce/q:85/plain/local:///images/dog.jpg");
  });

  it("emits car with enlarge", () => {
    const state = {
      ...defaultFiddleState,
      cropEnabled: true,
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1,
      cropAspectRatioEnlarge: true,
    };
    expect(optionSegments(state)).toContain("car:1:1");
  });

  it("emits car without enlarge", () => {
    const state = {
      ...defaultFiddleState,
      cropEnabled: true,
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: false,
    };
    expect(optionSegments(state)).toContain("car:1.5");
  });

  it("does not emit an empty option segment when all tools are disabled", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: false,
      cropEnabled: false,
      gravityEnabled: false,
      formatEnabled: false,
      qualityEnabled: false,
    };

    expect(optionSegments(state)).toEqual([]);
    expect(buildProcessingPath(state)).toBe("/img/_/plain/local:///images/dog.jpg");
  });

  it("shows automatic output as pending until response metadata is available", () => {
    expect(resolvedOutputLabel(defaultFiddleState, null)).toBe("auto");
    expect(
      resolvedOutputLabel(defaultFiddleState, {
        width: 640,
        height: 480,
        bytes: 10_000,
        contentType: "image/avif",
      }),
    ).toBe("auto -> avif");
    expect(resolvedOutputLabel({ ...defaultFiddleState, formatEnabled: true, format: "png" })).toBe(
      "png",
    );
  });

  it("formats the processed image dimensions and encoded byte size", () => {
    expect(
      processedSizeLabel({
        width: 640,
        height: 480,
        bytes: 552_960,
        contentType: "image/jpeg",
      }),
    ).toBe("640 × 480 (540 kB)");
    expect(processedSizeLabel({ width: 300, height: 200, bytes: null, contentType: null })).toBe(
      "300 × 200",
    );
  });
});

describe("fiddle URL state", () => {
  it("builds a shareable fiddle route from generated request options", () => {
    const state = {
      ...defaultFiddleState,
      resizeEnabled: true,
      gravityEnabled: true,
      formatEnabled: true,
      qualityEnabled: true,
    };

    expect(fiddlePathForState(state)).toBe(
      "/rs:fill:640:360:0/g:ce/f:jpeg/q:85/plain/local:///images/dog.jpg",
    );
  });

  it("parses a shareable fiddle route into enabled controls", () => {
    const parsed = parseFiddlePath(
      "/rs:fill:640:360:0/g:ce/f:jpeg/q:85/plain/local:///images/dog.jpg",
    );

    expect(parsed).toMatchObject({
      source: "images/dog.jpg",
      resizeEnabled: true,
      resizeMode: "fill",
      width: 640,
      height: 360,
      gravityEnabled: true,
      gravityMode: "anchor",
      gravity: "ce",
      formatEnabled: true,
      format: "jpeg",
      qualityEnabled: true,
      quality: 85,
    });
  });

  it("round-trips trim with threshold only through the fiddle path", () => {
    const parsed = parseFiddlePath("/trim:10/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto",
      trimEqualHor: false,
      trimEqualVer: false,
    });

    expect(fiddlePathForState(parsed)).toBe("/trim:10/plain/local:///images/dog.jpg");
  });

  it("round-trips trim with color through the fiddle path", () => {
    const parsed = parseFiddlePath("/trim:10:ff00ff/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "color",
      trimColor: "#ff00ff",
    });

    expect(fiddlePathForState(parsed)).toBe("/trim:10:ff00ff/plain/local:///images/dog.jpg");
  });

  it("round-trips trim with empty color slot and flags through the fiddle path", () => {
    const parsed = parseFiddlePath("/trim:10::1:1/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 10,
      trimBackgroundMode: "auto",
      trimEqualHor: true,
      trimEqualVer: true,
    });

    expect(fiddlePathForState(parsed)).toBe("/trim:10::1:1/plain/local:///images/dog.jpg");
  });

  it("round-trips trim short alias (t) through the fiddle path", () => {
    const parsed = parseFiddlePath("/t:15/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      trimEnabled: true,
      trimThreshold: 15,
    });

    // Re-emits using the long form "trim:"
    expect(fiddlePathForState(parsed)).toBe("/trim:15/plain/local:///images/dog.jpg");
  });

  it("rejects invalid trim values in fiddle routes", () => {
    expect(parseFiddlePath("/trim:-1/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/trim:bad/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/trim:10:zzz/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/trim:10:ff00ff:2:0/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/trim:10:ff00ff:0:2/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("round-trips size autoquality through the fiddle path", () => {
    const parsed = parseFiddlePath("/autoquality:size:40000:60:90/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      autoqualityMethod: "size",
      autoqualitySizeTarget: 40000,
      autoqualityMinQuality: 60,
      autoqualityMaxQuality: 90,
    });

    expect(fiddlePathForState(parsed)).toBe(
      "/autoquality:size:40000:60:90/plain/local:///images/dog.jpg",
    );
  });

  it("round-trips ssim2 autoquality including allowed_error", () => {
    const parsed = parseFiddlePath("/autoquality:ssim2:80:50:95:1.5/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      autoqualityMethod: "ssim2",
      autoqualitySsim2Target: 80,
      autoqualityMinQuality: 50,
      autoqualityMaxQuality: 95,
      autoqualityAllowedError: 1.5,
    });

    expect(fiddlePathForState(parsed)).toBe(
      "/autoquality:ssim2:80:50:95:1.5/plain/local:///images/dog.jpg",
    );
  });

  it("round-trips butteraugli autoquality including allowed_error", () => {
    const parsed = parseFiddlePath(
      "/autoquality:butteraugli:1:50:95:0.1/plain/local:///images/dog.jpg",
    );

    expect(parsed).toMatchObject({
      autoqualityMethod: "butteraugli",
      autoqualityButteraugliTarget: 1,
      autoqualityMinQuality: 50,
      autoqualityMaxQuality: 95,
      autoqualityAllowedError: 0.1,
    });

    expect(fiddlePathForState(parsed)).toBe(
      "/autoquality:butteraugli:1:50:95:0.1/plain/local:///images/dog.jpg",
    );
  });

  it("rejects a butteraugli target outside the 0..25 distance range (falls back to default)", () => {
    const parsed = parseFiddlePath("/autoquality:butteraugli:30/plain/local:///images/dog.jpg");

    // The method still applies, but the out-of-range distance is rejected by
    // parseDistanceValue and the target falls back to the default (1), never 30.
    expect(parsed.autoqualityMethod).toBe("butteraugli");
    expect(parsed.autoqualityButteraugliTarget).toBe(1);
  });

  it("parses the aq short alias for autoquality", () => {
    const parsed = parseFiddlePath("/aq:size:40000/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      autoqualityMethod: "size",
      autoqualitySizeTarget: 40000,
    });
  });

  it("treats autoquality:none as the disabled method", () => {
    const parsed = parseFiddlePath("/autoquality:none/plain/local:///images/dog.jpg");

    expect(parsed.autoqualityMethod).toBe("none");
    expect(optionSegments(parsed)).toEqual([]);
  });

  it("rejects invalid autoquality values in fiddle routes", () => {
    expect(parseFiddlePath("/autoquality:bogus/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/autoquality:size:1:2:3:4/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("round-trips max bytes through the mb alias", () => {
    const parsed = parseFiddlePath("/mb:75000/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      maxBytesEnabled: true,
      maxBytes: 75000,
    });

    expect(fiddlePathForState(parsed)).toBe("/mb:75000/plain/local:///images/dog.jpg");
  });

  it("parses the long max_bytes alias", () => {
    const parsed = parseFiddlePath("/max_bytes:75000/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({
      maxBytesEnabled: true,
      maxBytes: 75000,
    });
  });

  it("rejects invalid max bytes values in fiddle routes", () => {
    expect(parseFiddlePath("/mb:0/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/mb:-5/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/mb:bad/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
  });

  it("parses crop, orientation, scale, canvas, padding, background, and effects options", () => {
    const parsed = parseFiddlePath(
      "/ar:1/fl:0:1/rot:90/c:0.5:0.25:no/z:1.25/dpr:2/mw:320/mh:240/exar:1/pd:1:2:3:4/bg:ffcc00/bga:0.42/bl:2.5/sh:0.7/pix:8/mc:0.5:ffcc00/dt:0.25:112233:ffeecc/br:20/co:1.4/sa:0.7/plain/local:///images/beach.jpg",
    );

    expect(parsed).toMatchObject({
      source: "images/beach.jpg",
      autoRotateEnabled: true,
      flip: "vertical",
      rotate: 90,
      cropEnabled: true,
      cropWidthUnit: "percent",
      cropWidthPercent: 50,
      cropHeightUnit: "percent",
      cropHeightPercent: 25,
      cropGravity: "no",
      zoomEnabled: true,
      zoom: 1.25,
      dprEnabled: true,
      dpr: 2,
      minWidthEnabled: true,
      minWidth: 320,
      minHeightEnabled: true,
      minHeight: 240,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "ce",
      paddingEnabled: true,
      paddingTop: 1,
      paddingRight: 2,
      paddingBottom: 3,
      paddingLeft: 4,
      backgroundEnabled: true,
      backgroundColor: "#ffcc00",
      backgroundAlpha: 0.42,
      blurEnabled: true,
      blur: 2.5,
      sharpenEnabled: true,
      sharpen: 0.7,
      pixelateEnabled: true,
      pixelate: 8,
      monochromeEnabled: true,
      monochromeIntensity: 0.5,
      monochromeColor: "#ffcc00",
      duotoneEnabled: true,
      duotoneIntensity: 0.25,
      duotoneShadow: "#112233",
      duotoneHighlight: "#ffeecc",
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: 1.4,
      saturationEnabled: true,
      saturation: 0.7,
    });
  });

  it("parses long aliases for color effect options", () => {
    expect(
      parseFiddlePath("/brightness:20/contrast:1.4/saturation:0.7/plain/local:///images/dog.jpg"),
    ).toMatchObject({
      brightnessEnabled: true,
      brightness: 20,
      contrastEnabled: true,
      contrast: 1.4,
      saturationEnabled: true,
      saturation: 0.7,
    });
  });

  it("treats contrast and saturation of one as a fiddle no-op", () => {
    expect(parseFiddlePath("/co:1/plain/local:///images/dog.jpg")).toMatchObject({
      contrastEnabled: false,
      contrast: defaultFiddleState.contrast,
    });

    expect(parseFiddlePath("/sa:1/plain/local:///images/dog.jpg")).toMatchObject({
      saturationEnabled: false,
      saturation: defaultFiddleState.saturation,
    });
  });

  it("enables brightness for a zero-crossing negative level", () => {
    expect(parseFiddlePath("/br:-200/plain/local:///images/dog.jpg")).toMatchObject({
      brightnessEnabled: true,
      brightness: -200,
    });
  });

  it("round-trips colorize through the fiddle path", () => {
    const state = {
      ...defaultFiddleState,
      colorizeEnabled: true,
      colorizeOpacity: 0.5,
      colorizeColor: "#ff0000",
      colorizeKeepAlpha: true,
    };

    expect(parseFiddlePath(fiddlePathForState(state))).toMatchObject({
      colorizeEnabled: true,
      colorizeOpacity: 0.5,
      colorizeColor: "#ff0000",
      colorizeKeepAlpha: true,
    });
  });

  it("round-trips gradient through the fiddle path", () => {
    const state = {
      ...defaultFiddleState,
      gradientEnabled: true,
      gradientOpacity: 0.6,
      gradientColor: "#112233",
      gradientDirection: "right",
      gradientStart: 0.25,
      gradientStop: 0.75,
    };

    expect(parseFiddlePath(fiddlePathForState(state))).toMatchObject({
      gradientEnabled: true,
      gradientOpacity: 0.6,
      gradientColor: "#112233",
      gradientDirection: "right",
      gradientStart: 0.25,
      gradientStop: 0.75,
    });
  });

  it("parses colorize and gradient long aliases", () => {
    expect(
      parseFiddlePath(
        "/colorize:0.4:00ff00:0/gradient:0.5:000000:up:0:1/plain/local:///images/dog.jpg",
      ),
    ).toMatchObject({
      colorizeEnabled: true,
      colorizeOpacity: 0.4,
      colorizeColor: "#00ff00",
      colorizeKeepAlpha: false,
      gradientEnabled: true,
      gradientOpacity: 0.5,
      gradientColor: "#000000",
      gradientDirection: "up",
      gradientStart: 0,
      gradientStop: 1,
    });
  });

  it("uses duotone defaults for omitted fiddle route colors", () => {
    expect(parseFiddlePath("/dt:0.5:112233/plain/local:///images/dog.jpg")).toMatchObject({
      duotoneEnabled: true,
      duotoneIntensity: 0.5,
      duotoneShadow: "#112233",
      duotoneHighlight: defaultFiddleState.duotoneHighlight,
    });

    expect(parseFiddlePath("/dt:0.5::ffeecc/plain/local:///images/dog.jpg")).toMatchObject({
      duotoneEnabled: true,
      duotoneIntensity: 0.5,
      duotoneShadow: defaultFiddleState.duotoneShadow,
      duotoneHighlight: "#ffeecc",
    });
  });

  it("treats pixelate size one as a fiddle no-op", () => {
    expect(parseFiddlePath("/pix:1/plain/local:///images/dog.jpg")).toEqual({
      ...defaultFiddleState,
      pixelateEnabled: false,
      pixelate: defaultFiddleState.pixelate,
    });
  });

  it("treats no-op-valued effects as fiddle no-ops", () => {
    expect(
      parseFiddlePath("/bl:0/sh:0/pix:0/br:0/co:1/sa:1/plain/local:///images/dog.jpg"),
    ).toEqual({
      ...defaultFiddleState,
      blurEnabled: false,
      blur: defaultFiddleState.blur,
      sharpenEnabled: false,
      sharpen: defaultFiddleState.sharpen,
      pixelateEnabled: false,
      pixelate: defaultFiddleState.pixelate,
      monochromeEnabled: false,
      monochromeIntensity: defaultFiddleState.monochromeIntensity,
      monochromeColor: defaultFiddleState.monochromeColor,
      duotoneEnabled: false,
      duotoneIntensity: defaultFiddleState.duotoneIntensity,
      duotoneShadow: defaultFiddleState.duotoneShadow,
      duotoneHighlight: defaultFiddleState.duotoneHighlight,
      brightnessEnabled: false,
      brightness: defaultFiddleState.brightness,
      contrastEnabled: false,
      contrast: defaultFiddleState.contrast,
      saturationEnabled: false,
      saturation: defaultFiddleState.saturation,
    });
  });

  it("expands accordions that contain active URL state", () => {
    const state = parseFiddlePath("/ar:1/z:1.5/br:20/plain/local:///images/dog.jpg");

    expect(expandedToolboxesForState(state)).toEqual({
      effectsOpen: true,
      orientationOpen: true,
      scaleOptionsOpen: true,
      requestOpen: true,
    });
  });

  it("parses car with and without enlarge", () => {
    expect(parseFiddlePath("/car:1.5/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: false,
    });

    expect(parseFiddlePath("/car:1.5:1/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: true,
    });

    expect(parseFiddlePath("/car:2:0/plain/local:///images/dog.jpg")).toMatchObject({
      cropAspectRatioEnabled: true,
      cropAspectRatio: 2,
      cropAspectRatioEnlarge: false,
    });
  });

  it("round-trips a car-only path through parse and emit", () => {
    const parsed = parseFiddlePath("/car:1.5:1/plain/local:///images/dog.jpg");

    expect(parsed).not.toBeNull();
    // car must survive serialization even though cropEnabled stays false.
    expect(optionSegments(parsed as FiddleState)).toContain("car:1.5:1");
  });

  it("rejects invalid car values in fiddle routes", () => {
    expect(parseFiddlePath("/car:-1/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/car:bad/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/car:1.5:bad/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/car:1:2:3/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
  });

  it("falls back to defaults for invalid fiddle routes", () => {
    expect(parseFiddlePath("/not-supported/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/rs:fill:640:360:0/plain/images/dog.jpg")).toEqual(defaultFiddleState);
    expect(
      parseFiddlePath("/not-a-valid-option/rs:fill:640:360:0/plain/local:///images/dog.jpg"),
    ).toEqual(defaultFiddleState);
  });

  it("rejects invalid quality values in fiddle routes", () => {
    expect(parseFiddlePath("/q:-1/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/q:101/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/q:85.5/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
  });

  it("rejects invalid color effect values in fiddle routes", () => {
    expect(parseFiddlePath("/br:abc/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/co:abc/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/sa:abc/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/mc:1.1/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/dt:0.5:zzz/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("rejects out-of-range colorize and gradient values in fiddle routes", () => {
    expect(parseFiddlePath("/col:1.1:ff0000:0/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/col:0.5:zzz:0/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
    expect(parseFiddlePath("/gr:0.5:000000:down:1.5:1/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("emits nothing for default metadata and color-profile state (all true)", () => {
    expect(optionSegments(defaultFiddleState)).toEqual([]);
  });

  it("emits sm:0 when stripMetadata is false", () => {
    const state = { ...defaultFiddleState, stripMetadata: false, keepCopyright: false };

    expect(optionSegments(state)).toContain("sm:0");
    expect(optionSegments(state)).not.toContain("kcr:0");
  });

  it("emits kcr:0 when stripMetadata is true but keepCopyright is false", () => {
    const state = { ...defaultFiddleState, stripMetadata: true, keepCopyright: false };

    expect(optionSegments(state)).toContain("kcr:0");
    expect(optionSegments(state)).not.toContain("sm:0");
  });

  it("does not emit kcr when stripMetadata is false (canonical omission)", () => {
    const state = { ...defaultFiddleState, stripMetadata: false, keepCopyright: true };

    const segments = optionSegments(state);

    expect(segments).toContain("sm:0");
    expect(segments).not.toContain("kcr:0");
    expect(segments).not.toContain("kcr:1");
  });

  it("emits scp:0 when stripColorProfile is false", () => {
    const state = { ...defaultFiddleState, stripColorProfile: false };

    expect(optionSegments(state)).toContain("scp:0");
  });

  it("round-trips sm:0 through parse and emit", () => {
    const parsed = parseFiddlePath("/sm:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripMetadata: false, keepCopyright: false });
    expect(optionSegments(parsed)).toContain("sm:0");
    expect(optionSegments(parsed)).not.toContain("kcr:0");
  });

  it("round-trips kcr:0 through parse and emit", () => {
    const parsed = parseFiddlePath("/kcr:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripMetadata: true, keepCopyright: false });
    expect(optionSegments(parsed)).toContain("kcr:0");
    expect(optionSegments(parsed)).not.toContain("sm:0");
  });

  it("round-trips scp:0 through parse and emit", () => {
    const parsed = parseFiddlePath("/scp:0/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ stripColorProfile: false });
    expect(optionSegments(parsed)).toContain("scp:0");
  });

  it("omits cp for the default (none) color-profile state", () => {
    expect(optionSegments(defaultFiddleState)).not.toContain("cp:none");
    expect(optionSegments(defaultFiddleState).some((seg) => seg.startsWith("cp:"))).toBe(false);
  });

  it("emits cp:<target> for non-none color profiles", () => {
    expect(optionSegments({ ...defaultFiddleState, colorProfile: "srgb" })).toContain("cp:srgb");
    expect(optionSegments({ ...defaultFiddleState, colorProfile: "display-p3" })).toContain(
      "cp:display-p3",
    );
    expect(optionSegments({ ...defaultFiddleState, colorProfile: "adobe-rgb" })).toContain(
      "cp:adobe-rgb",
    );
  });

  it("round-trips cp targets through parse and emit", () => {
    const parsed = parseFiddlePath("/cp:display-p3/plain/local:///images/dog.jpg");

    expect(parsed).toMatchObject({ colorProfile: "display-p3" });
    expect(optionSegments(parsed)).toContain("cp:display-p3");
  });

  it("accepts the icc alias and canonicalizes color-profile aliases", () => {
    expect(parseFiddlePath("/icc:srgb/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "srgb",
    });
    expect(parseFiddlePath("/cp:p3/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "display-p3",
    });
    expect(parseFiddlePath("/cp:adobergb/plain/local:///images/dog.jpg")).toMatchObject({
      colorProfile: "adobe-rgb",
    });
  });

  it("rejects unknown cp values in fiddle routes", () => {
    expect(parseFiddlePath("/cp:cmyk/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/cp:/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/cp:srgb:extra/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("round-trips ph:1 through the fiddle path", () => {
    const state = { ...defaultFiddleState, preserveHdr: true };

    expect(optionSegments(state)).toContain("ph:1");

    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed).toMatchObject({ preserveHdr: true });
  });

  it("normalizes keepCopyright to false when sm:0 is parsed without kcr", () => {
    const parsedSmOnly = parseFiddlePath("/sm:0/plain/local:///images/dog.jpg");

    expect(parsedSmOnly).toMatchObject({ stripMetadata: false, keepCopyright: false });
  });

  it("normalizes keepCopyright to false regardless of sm/kcr segment order", () => {
    const kcrThenSm = parseFiddlePath("/kcr:1/sm:0/plain/local:///images/dog.jpg");
    const smThenKcr = parseFiddlePath("/sm:0/kcr:1/plain/local:///images/dog.jpg");

    expect(kcrThenSm).toMatchObject({ stripMetadata: false, keepCopyright: false });
    expect(smThenKcr).toMatchObject({ stripMetadata: false, keepCopyright: false });
  });

  it("accepts boolean aliases for sm, kcr, and scp", () => {
    expect(parseFiddlePath("/sm:1/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseFiddlePath("/sm:t/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseFiddlePath("/sm:true/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: true,
    });
    expect(parseFiddlePath("/sm:f/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: false,
    });
    expect(parseFiddlePath("/sm:false/plain/local:///images/dog.jpg")).toMatchObject({
      stripMetadata: false,
    });
    expect(parseFiddlePath("/kcr:0/plain/local:///images/dog.jpg")).toMatchObject({
      keepCopyright: false,
    });
    expect(parseFiddlePath("/scp:f/plain/local:///images/dog.jpg")).toMatchObject({
      stripColorProfile: false,
    });
  });

  it("rejects invalid sm/kcr/scp values in fiddle routes", () => {
    expect(parseFiddlePath("/sm:yes/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/kcr:2/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/scp:/plain/local:///images/dog.jpg")).toEqual(defaultFiddleState);
    expect(parseFiddlePath("/sm:0:extra/plain/local:///images/dog.jpg")).toEqual(
      defaultFiddleState,
    );
  });

  it("resets processing options while keeping source and signature settings", () => {
    const reset = resetFiddleSettings({
      ...defaultFiddleState,
      source: "images/beach.jpg",
      signatureMode: "signed",
      signatureKey: "abcd",
      signatureSalt: "1234",
      resizeEnabled: true,
      gravityEnabled: true,
      qualityEnabled: true,
      cropEnabled: true,
      cropWidth: 24,
      cropHeight: 24,
    });

    expect(reset).toMatchObject({
      ...defaultFiddleState,
      source: "images/beach.jpg",
      signatureMode: "signed",
      signatureKey: "abcd",
      signatureSalt: "1234",
      cropWidth: cropPixelLimit("images/beach.jpg", "width").max,
      cropHeight: cropPixelLimit("images/beach.jpg", "height").max,
    });
    expect(optionSegments(reset)).toEqual([]);
    expect(fiddlePathForState(reset)).toBe("/plain/local:///images/beach.jpg");
  });
});

describe("object-gravity + focal-point segment building", () => {
  it("builds a focal-point gravity segment", () => {
    const state = {
      ...defaultFiddleState,
      gravityEnabled: true,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.25,
      gravityFocalY: 0.75,
    };
    expect(gravitySegment(state)).toBe("g:fp:0.25:0.75");
  });

  it("builds a weighted object segment from selected classes", () => {
    const state = {
      ...defaultFiddleState,
      gravityMode: "object" as const,
      objSubMode: "weighted" as const,
      objSelectedClasses: ["dog", "person"],
      objWeights: { dog: 2, person: 1 },
    };
    expect(objGravitySegmentFromState(state)).toBe("g:objw:dog:2:person:1");
  });
});

import { describe, expect, it } from "vitest";
import {
  controlStateFromOptions,
  controlOptionSegments,
  normalizeControlEdit,
  updateControlOptions,
} from "./api-controls";

const source = "images/dog.jpg";
const defaults = () => controlStateFromOptions("", source);

describe("visual controls serialize API requests", () => {
  it("uses API resize modes and automatic dimensions", () => {
    const state = defaults();
    Object.assign(state, {
      resizeEnabled: true,
      width: 480,
      resizeHeightUnit: "auto",
      resizeMode: "cover",
      enlarge: true,
    });
    expect(controlOptionSegments(state)).toEqual(["w=480", "h=auto", "fit=cover", "enlarge"]);
  });

  it("maps crop full and percentage units, ratio, and focal point", () => {
    const state = defaults();
    Object.assign(state, {
      cropEnabled: true,
      cropWidthUnit: "percent",
      cropWidthPercent: 65,
      cropHeightUnit: "full",
      cropAspectRatioEnabled: true,
      cropAspectRatio: 1.5,
      cropAspectRatioEnlarge: true,
      gravityEnabled: true,
      gravityMode: "focalPoint",
      gravityFocalX: 0.2,
      gravityFocalY: 0.75,
    });
    expect(controlOptionSegments(state)).toEqual([
      "crop=65pct,100pct",
      "crop-ratio=1.5",
      "crop-ratio-enlarge",
      "focus=0.2,0.75",
    ]);
  });

  it("maps weighted detection without vendor gravity syntax", () => {
    const state = defaults();
    Object.assign(state, {
      gravityEnabled: true,
      gravityMode: "object",
      objSubMode: "weighted",
      objSelectedClasses: ["face", "all"],
      objWeights: { face: 3, all: 1 },
    });
    expect(controlOptionSegments(state)).toEqual(["detect=all:1,face:3"]);
  });

  it("maps effects and background alpha", () => {
    const state = defaults();
    Object.assign(state, {
      blurEnabled: true,
      blur: 3,
      monochromeEnabled: true,
      monochromeIntensity: 0.7,
      monochromeColor: "#123456",
      colorizeEnabled: true,
      colorizeOpacity: 0.3,
      colorizeColor: "#aabbcc",
      colorizeKeepAlpha: true,
      backgroundEnabled: true,
      backgroundColor: "#112233",
      backgroundAlpha: 0.5,
    });
    expect(controlOptionSegments(state)).toEqual([
      "bg=112233,0.5",
      "blur=3",
      "monochrome=0.7,123456",
      "colorize=0.3,aabbcc,keep-alpha",
    ]);
  });

  it("maps orientation, trim symmetry, padding, and canvas", () => {
    const state = defaults();
    Object.assign(state, {
      autoRotateEnabled: false,
      rotate: 90,
      flip: "both",
      trimEnabled: true,
      trimBackgroundMode: "color",
      trimThreshold: 12,
      trimEqualHor: true,
      trimEqualVer: true,
      paddingEnabled: true,
      aspectCanvasEnabled: true,
      aspectCanvasGravity: "bottom-right",
    });
    expect(controlOptionSegments(state)).toEqual([
      "orient=none",
      "rotate=90",
      "flip=hv",
      "trim=ffffff,12",
      "trim-symmetry=hv",
      "extend-ratio",
      "extend-at=bottom-right",
      "pad=24,24,24,24",
    ]);
  });

  it("serializes codec options with named fields and explicit false values", () => {
    const state = defaults();
    state.jpegOptions = { progressive: false, no_subsample: true, quant_table: 3 };
    state.pngOptions = { interlaced: true, quantize: true, bitdepth: 4 };
    state.webpOptions = { compression: "lossy", smart_subsample: false, preset: "photo" };
    state.avifOptions = { subsample: "off" };
    expect(controlOptionSegments(state)).toEqual([
      "jpeg-options=progressive:false,subsample:off,quant-table:3",
      "png-options=interlace,palette,bitdepth:4",
      "webp-options=lossless:false,near-lossless:false,smart-subsample:false,preset:photo",
      "avif-options=subsample:off",
    ]);
  });

  it("maps quality search and metadata policies", () => {
    const state = defaults();
    Object.assign(state, {
      formatEnabled: true,
      format: "jpeg",
      qualityEnabled: true,
      quality: 82,
      autoqualityMethod: "ssimulacra2",
      autoqualityMinQuality: 40,
      autoqualityMaxQuality: 90,
      autoqualitySsim2Target: 80,
      maxBytesEnabled: true,
      maxBytes: 30000,
      stripMetadata: false,
      colorProfile: "display-p3",
      preserveHdr: true,
    });
    expect(controlOptionSegments(state)).toEqual([
      "format=jpeg",
      "q=82",
      "autoquality=ssimulacra2,target:80,min:40,max:90,error:1",
      "max-bytes=30000",
      "meta=keep",
      "profile=display-p3",
      "hdr=preserve",
    ]);
  });
});

describe("deep links and edits", () => {
  it("removes a processing group when its last operation is disabled", () => {
    const options = "w=500/-/trim=fff";
    const before = controlStateFromOptions(options, source, 1);
    expect(updateControlOptions(options, 1, before, { ...before, trimEnabled: false })).toBe(
      "w=500",
    );
  });
  it("emits explicit stripping when copyright preservation is disabled", () => {
    const before = controlStateFromOptions("meta=copyright", source);
    expect(
      updateControlOptions("meta=copyright", 0, before, { ...before, keepCopyright: false }),
    ).toBe("meta=strip");
  });

  it("can re-enable resize after switching both dimensions to auto", () => {
    const before = controlStateFromOptions("w=400", source);
    const disabled = normalizeControlEdit(before, { ...before, resizeWidthUnit: "auto" });
    const enabled = normalizeControlEdit(disabled, { ...disabled, resizeEnabled: true });
    expect(enabled.resizeWidthUnit).toBe("px");
  });

  it.each(["anchor-offset=10", "colorize=0.3", "w=abc/blur=-", "crop=50pct", "gradient="])(
    "keeps the editor usable with an incomplete path: %s",
    (options) => {
      const state = controlStateFromOptions(options, source);
      expect(() => controlOptionSegments(state)).not.toThrow();
      expect(
        Object.values(state)
          .filter((value) => typeof value === "number")
          .every(Number.isFinite),
      ).toBe(true);
    },
  );

  it("keeps offset units when moving one axis", () => {
    const options = "crop=60pct,60pct/anchor=top-left/anchor-offset=10pct,5pct";
    const before = controlStateFromOptions(options, source);
    expect(updateControlOptions(options, 0, before, { ...before, gravityOffsetX: 20 })).toBe(
      "crop=60pct,60pct/anchor=top-left/anchor-offset=20pct,5pct",
    );
  });

  it("does not inject quality search defaults when changing just the target", () => {
    const options = "format=jxl/autoquality=butteraugli,target:1";
    const before = controlStateFromOptions(options, source);
    expect(
      updateControlOptions(options, 0, before, { ...before, autoqualityButteraugliTarget: 2 }),
    ).toBe("format=jxl/autoquality=butteraugli,target:2");
  });

  it("removes an encoder option when its final field is unset", () => {
    const options = "w=400/jpeg-options=progressive";
    const before = controlStateFromOptions(options, source);
    expect(updateControlOptions(options, 0, before, { ...before, jpegOptions: {} })).toBe("w=400");
  });

  it("removes canvas placement when resize is turned off", () => {
    const options = "w=600/h=600/extend/extend-at=bottom/extend-offset=5pct,0";
    const before = controlStateFromOptions(options, source);
    const after = normalizeControlEdit(before, { ...before, resizeEnabled: false });
    expect(updateControlOptions(options, 0, before, after)).toBe("");
  });

  it("switches canvas modes and supplies concrete dimensions", () => {
    const before = controlStateFromOptions("w=600/h=600/extend", source);
    const after = normalizeControlEdit(before, { ...before, aspectCanvasEnabled: true });
    const options = updateControlOptions("w=600/h=600/extend", 0, before, after);
    expect(options.split("/")).toContain("extend-ratio");
    expect(options.split("/")).not.toContain("extend");
    const initial = controlStateFromOptions("w=800", source);
    expect(normalizeControlEdit(initial, { ...initial, resizeExtendEnabled: true })).toMatchObject({
      resizeWidthUnit: "px",
      resizeHeightUnit: "px",
    });
  });

  it("populates restored widgets from an API URL", () => {
    const state = controlStateFromOptions(
      "w=600/h=400/fit=cover/crop=80pct,100pct/crop-ratio=16:9/focus=0.3,0.6/blur=2/format=webp/q=70",
      source,
    );
    expect(state).toMatchObject({
      resizeEnabled: true,
      width: 600,
      height: 400,
      resizeMode: "cover",
      cropEnabled: true,
      cropWidthUnit: "percent",
      cropWidthPercent: 80,
      cropHeightUnit: "full",
      cropAspectRatio: 16 / 9,
      gravityMode: "focalPoint",
      gravityFocalX: 0.3,
      gravityFocalY: 0.6,
      blurEnabled: true,
      blur: 2,
      format: "webp",
      quality: 70,
    });
  });

  it("changes only the edited control and preserves unrepresented API options", () => {
    const options = "preset=framed/w=800/zoom=1.5,2/extend-offset=2pct,0/debug/output=blurhash";
    const before = controlStateFromOptions(options, source);
    const after = { ...before, width: 400 };
    expect(updateControlOptions(options, 0, before, after)).toBe(
      "preset=framed/w=400/zoom=1.5,2/extend-offset=2pct,0/debug/output=blurhash",
    );
  });

  it("edits the selected processing group and request-wide format without duplicates", () => {
    const options = "w=800/format=jpeg/-/rotate=90/w=300/debug";
    const before = controlStateFromOptions(options, source, 1);
    expect(before).toMatchObject({ width: 300, rotate: 90, format: "jpeg", formatEnabled: true });
    expect(updateControlOptions(options, 1, before, { ...before, width: 200, format: "png" })).toBe(
      "w=800/format=png/-/rotate=90/w=200/debug",
    );
  });

  it("turns operations off and switches crop guides without conflicting options", () => {
    const options = "w=400/h=400/fit=cover/anchor=top/anchor-offset=10,20/blur=2";
    const before = controlStateFromOptions(options, source);
    const after = {
      ...before,
      blurEnabled: false,
      gravityMode: "focalPoint" as const,
      gravityFocalX: 0.1,
      gravityFocalY: 0.7,
    };
    expect(updateControlOptions(options, 0, before, after)).toBe(
      "w=400/h=400/fit=cover/focus=0.1,0.7",
    );
  });

  it("preserves codec settings with no portable widget when another codec field changes", () => {
    const options =
      "w=400/png-options=palette,filter:paeth,bitdepth:4/webp-options=effort:3,lossless";
    const before = controlStateFromOptions(options, source);
    const after = {
      ...before,
      pngOptions: { ...before.pngOptions, interlaced: true },
      webpOptions: { ...before.webpOptions, preset: "photo" as const },
    };
    const result = updateControlOptions(options, 0, before, after);
    expect(result).toContain("png-options=palette,filter:paeth,bitdepth:4,interlace");
    expect(result).toContain("webp-options=effort:3,lossless,preset:photo");
  });

  it.each([
    "rotate=30/flip=h/trim=abc,4/trim-symmetry=v",
    "crop=40pct,60pct/anchor=smart-face",
    "w=300/h=300/fit=cover/detect=all,face:3",
    "w=400/h=300/enlarge/extend/extend-at=left/pad=2,4/bg=fff,0.5",
    "blur=3/sharpen=2/pixelate=10/monochrome=0.5,red/duotone=1,black,white",
    "brightness=-30/contrast=1.4/saturation=0.5/colorize=0.3,blue,keep-alpha/gradient=0.4,black,left,0.1,0.8",
    "autoquality=butteraugli,target:1/format=jxl/meta=copyright/profile=preserve/hdr=preserve",
  ])("opening %s does not rewrite it", (options) => {
    const before = controlStateFromOptions(options, source);
    expect(updateControlOptions(options, 0, before, structuredClone(before))).toBe(options);
  });
});

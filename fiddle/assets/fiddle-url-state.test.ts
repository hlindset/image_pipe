import { describe, expect, it } from "vitest";
import { defaultFiddleState } from "./processing-path";
import { defaultNativeState } from "./native-path";
import {
  appPathForState,
  fiddlePathForState,
  parseAppPath,
  parseFiddlePath,
  resetFiddleSettings,
  type AppState,
} from "./fiddle-url-state";

function baseAppState(): AppState {
  return {
    provider: "imgproxy",
    native: { ...defaultNativeState },
    imgproxy: { ...defaultFiddleState },
  };
}

describe("appPathForState", () => {
  it("prefixes the imgproxy signed path", () => {
    expect(appPathForState(baseAppState())).toBe("/imgproxy/plain/local:///images/dog.jpg");
  });
});

describe("parseAppPath dispatch", () => {
  it("routes an imgproxy-prefixed path to the imgproxy slice", () => {
    const parsed = parseAppPath("/imgproxy/rs:fill:200:200:0/plain/local:///images/dog.jpg");
    expect(parsed.provider).toBe("imgproxy");
    expect(parsed.imgproxy.resizeEnabled).toBe(true);
    expect(parsed.imgproxy.width).toBe(200);
  });

  it("defaults to native for root or unknown prefix", () => {
    expect(parseAppPath("/").provider).toBe("native");
    expect(parseAppPath("/unknown").native).toEqual(defaultNativeState);
  });

  it("restores native options and groups from a browser URL", () => {
    const parsed = parseAppPath("/native/w=500/then/trim=fff/src/images/dog.jpg");
    expect(parsed.provider).toBe("native");
    expect(parsed.native.options).toBe("w=500/then/trim=fff");
    expect(appPathForState(parsed)).toBe("/native/w=500/then/trim=fff/src/images/dog.jpg");
  });

  it("does not leak inactive imgproxy settings into a native URL", () => {
    const state: AppState = {
      provider: "native",
      native: { ...defaultNativeState },
      imgproxy: { ...defaultFiddleState, resizeEnabled: true, width: 999 },
    };
    expect(appPathForState(state)).toBe("/native/w=800/src/images/dog.jpg");
  });
});

describe("source type round-trip", () => {
  for (const sourceType of ["local", "s3", "http"] as const) {
    it(`preserves sourceType=${sourceType} through path build + parse`, () => {
      const state = { ...defaultFiddleState, source: "images/dog.jpg" as const, sourceType };
      const path = fiddlePathForState(state);
      const parsed = parseFiddlePath(path);
      expect(parsed.source).toBe("images/dog.jpg");
      expect(parsed.sourceType).toBe(sourceType);
    });
  }

  it("preserves the imgproxy source type when resetting transform settings", () => {
    const reset = resetFiddleSettings({
      ...defaultFiddleState,
      sourceType: "s3",
      resizeEnabled: true,
    });

    expect(reset.sourceType).toBe("s3");
    expect(reset.resizeEnabled).toBe(false);
  });
});

describe("codec encoder option round-trip", () => {
  it("parses jpgo:::::1 setting only optimize_scans (omit-vs-false)", () => {
    const parsed = parseFiddlePath("/jpgo:::::1/plain/local:///images/dog.jpg");
    expect(parsed.jpegOptions).toEqual({ optimize_scans: true });
  });

  it("rejects non-canonical integers the backend would 400 (3.0, out-of-range)", () => {
    // "3.0" is not a canonical Integer.parse/1 value; 999 is out of 2..256.
    const decimal = parseFiddlePath("/pngo:::3.0/plain/local:///images/dog.jpg");
    expect(decimal.pngOptions.quantization_colors).toBeUndefined();

    const oor = parseFiddlePath("/pngo:::999/plain/local:///images/dog.jpg");
    expect(oor.pngOptions.quantization_colors).toBeUndefined();
  });

  it("round-trips a full jpgo through build + parse", () => {
    const state = {
      ...defaultFiddleState,
      jpegOptions: {
        progressive: true,
        no_subsample: false,
        trellis_quant: true,
        overshoot_deringing: false,
        optimize_scans: true,
        quant_table: 5,
      },
    };
    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed.jpegOptions).toEqual(state.jpegOptions);
  });

  it("round-trips pngo through build + parse", () => {
    const state = {
      ...defaultFiddleState,
      pngOptions: { interlaced: true, quantize: true, quantization_colors: 64 },
    };
    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed.pngOptions).toEqual(state.pngOptions);
  });

  it("round-trips webpo through build + parse", () => {
    const state = {
      ...defaultFiddleState,
      webpOptions: {
        compression: "near_lossless" as const,
        smart_subsample: true,
        preset: "drawing" as const,
      },
    };
    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed.webpOptions).toEqual(state.webpOptions);
  });

  it("round-trips avifo through build + parse", () => {
    const state = { ...defaultFiddleState, avifOptions: { subsample: "off" as const } };
    const parsed = parseFiddlePath(fiddlePathForState(state));
    expect(parsed.avifOptions).toEqual(state.avifOptions);
  });

  it("parses the full-name aliases identically to the short tokens", () => {
    const short = parseFiddlePath("/jpgo:1/plain/local:///images/dog.jpg");
    const long = parseFiddlePath("/jpeg_options:1/plain/local:///images/dog.jpg");
    expect(long.jpegOptions).toEqual(short.jpegOptions);
  });
});

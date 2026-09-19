import { describe, expect, it } from "vitest";
import { defaultNativeState } from "./native-path";
import { appPathForState, defaultAppState, parseAppPath } from "./fiddle-url-state";

describe("native browser state", () => {
  it("defaults root and unknown prefixes to the native request", () => {
    expect(parseAppPath("/")).toEqual(defaultAppState());
    expect(parseAppPath("/unknown")).toEqual(defaultAppState());
  });

  it("restores native options and groups from a browser URL", () => {
    const parsed = parseAppPath("/native/w=500/then/trim=fff/src/images/dog.jpg");

    expect(parsed.native.options).toBe("w=500/then/trim=fff");
    expect(appPathForState(parsed)).toBe("/native/w=500/then/trim=fff/src/images/dog.jpg");
  });

  it("falls back when a native URL has no valid source", () => {
    expect(parseAppPath("/native/w=500").native).toEqual(defaultNativeState);
  });

  for (const protection of ["signed", "signed-concealed"] as const) {
    it(`round trips the ${protection} protection mode without persisting protected bytes`, () => {
      const state = {
        native: { ...defaultNativeState, protection },
      };
      const path = appPathForState(state);

      expect(path).toBe(`/native/${protection}/w=800/src/images/dog.jpg`);
      expect(path).not.toContain("sig=");
      expect(path).not.toContain("enc/");
      expect(parseAppPath(path)).toEqual(state);
    });
  }
});

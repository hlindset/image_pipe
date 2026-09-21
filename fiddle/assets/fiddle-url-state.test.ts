import { describe, expect, it } from "vitest";
import { defaultApiState } from "./api-path";
import { appPathForState, defaultAppState, parseAppPath } from "./fiddle-url-state";

describe("API browser state", () => {
  it("defaults root and unknown prefixes to the API request", () => {
    expect(parseAppPath("/")).toEqual(defaultAppState());
    expect(parseAppPath("/unknown")).toEqual(defaultAppState());
  });

  it("restores API options and groups from a browser URL", () => {
    const parsed = parseAppPath("/edit/w=500/then/trim=fff/src/images/dog.jpg");

    expect(parsed.api.options).toBe("w=500/then/trim=fff");
    expect(appPathForState(parsed)).toBe("/edit/w=500/then/trim=fff/src/images/dog.jpg");
  });

  it("falls back when an API URL has no valid source", () => {
    expect(parseAppPath("/edit/w=500").api).toEqual(defaultApiState);
  });

  for (const protection of ["signed", "signed-concealed", "signed-concealed-random"] as const) {
    it(`round trips the ${protection} protection mode without persisting protected bytes`, () => {
      const state = {
        api: { ...defaultApiState, protection },
      };
      const path = appPathForState(state);

      expect(path).toBe(`/edit/${protection}/w=800/src/images/dog.jpg`);
      expect(path).not.toContain("sig=");
      expect(path).not.toContain("enc/");
      expect(parseAppPath(path)).toEqual(state);
    });
  }
});

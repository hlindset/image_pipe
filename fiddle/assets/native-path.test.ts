import { describe, expect, it } from "vitest";
import {
  defaultNativeState,
  nativeBrowserPath,
  nativeFetchPath,
  parseNativeTail,
} from "./native-path";

describe("native paths", () => {
  it("builds requests with explicit groups and a separate source", () => {
    const state = { ...defaultNativeState, options: "w=500/then/trim=fff" };
    expect(nativeFetchPath(state)).toBe("/native-image/w=500/then/trim=fff/src/images/dog.jpg");
    expect(parseNativeTail(nativeBrowserPath(state).slice("/native/".length))).toEqual(state);
  });

  it("round trips requests without transform options", () => {
    const state = { ...defaultNativeState, options: "" };
    expect(nativeFetchPath(state)).toBe("/native-image/src/images/dog.jpg");
    expect(parseNativeTail("src/images/dog.jpg")).toEqual(state);
  });

  it("leaves option validation to the native API and rejects unknown demo sources", () => {
    expect(parseNativeTail("w=oops/src/images/dog.jpg")?.options).toBe("w=oops");
    expect(parseNativeTail("w=500/src/private.jpg")).toBeNull();
    expect(parseNativeTail("w=500")).toBeNull();
  });
});

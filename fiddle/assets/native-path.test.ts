import { describe, expect, it } from "vitest";
import {
  defaultNativeState,
  nativeBrowserPath,
  nativeFetchPath,
  parseNativeTail,
  resetNativeSettings,
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

  for (const [sourceType, source] of [
    ["local", "images/dog.jpg"],
    ["s3", "s3%3A//sources/dog.jpg"],
    ["http", "http%3A//localhost%3A4000/images/dog.jpg"],
  ] as const) {
    it(`round trips the ${sourceType} source through the native URL`, () => {
      const state = { ...defaultNativeState, sourceType };
      expect(nativeFetchPath(state)).toBe(`/native-image/w=800/src/${source}`);
      expect(parseNativeTail(nativeBrowserPath(state).slice("/native/".length))).toEqual(state);
    });
  }

  it("rejects malformed escapes and sources outside the demo mounts", () => {
    expect(parseNativeTail("src/%xx")).toBeNull();
    expect(parseNativeTail("src/https%3A//example.com/images/dog.jpg")).toBeNull();
    expect(parseNativeTail("src/s3%3A//private/dog.jpg")).toBeNull();
  });

  it("leaves option validation to the native API and rejects unknown demo sources", () => {
    expect(parseNativeTail("w=oops/src/images/dog.jpg")?.options).toBe("w=oops");
    expect(parseNativeTail("w=500/src/private.jpg")).toBeNull();
    expect(parseNativeTail("w=500")).toBeNull();
  });

  it("preserves the native source type when resetting transform settings", () => {
    const reset = resetNativeSettings({
      ...defaultNativeState,
      sourceType: "http",
      options: "w=500/blur=2",
    });

    expect(reset).toEqual({
      ...defaultNativeState,
      sourceType: "http",
    });
  });
});

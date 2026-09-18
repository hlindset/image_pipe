import { describe, expect, it } from "vitest";
import {
  defaultNativeState,
  NativePathResolution,
  nativeBrowserPath,
  nativeFetchPath,
  parseNativeTail,
  resolveNativeFetchPath,
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

  it("leaves option validation to the API and rejects unknown demo sources", () => {
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

  it("asks the server for signed and concealed preview paths", async () => {
    const requests: Array<{ tail: string; protection: string }> = [];
    const fetcher = async (_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(JSON.parse(String(init?.body)));
      return new Response(JSON.stringify({ path: "/native-signed/sig=demo/w=64/enc=token" }), {
        headers: { "content-type": "application/json" },
      });
    };
    const state = {
      ...defaultNativeState,
      options: "w=64",
      protection: "signed-concealed" as const,
    };

    await expect(resolveNativeFetchPath(state, fetcher)).resolves.toBe(
      "/native-signed/sig=demo/w=64/enc=token",
    );
    expect(requests).toEqual([
      {
        tail: "w=64/src/images/dog.jpg",
        protection: "signed-concealed",
      },
    ]);
  });

  it("keeps unsigned previews local and does not call the signing helper", async () => {
    let called = false;
    const fetcher = async () => {
      called = true;
      return new Response();
    };

    await expect(resolveNativeFetchPath(defaultNativeState, fetcher)).resolves.toBe(
      "/native-image/w=800/src/images/dog.jpg",
    );
    expect(called).toBe(false);
  });

  it("keeps protected paths pending and rejects stale helper completions", () => {
    const resolution = new NativePathResolution();
    const first = resolution.begin({ ...defaultNativeState, protection: "signed" });
    const second = resolution.begin({ ...defaultNativeState, protection: "signed-concealed" });

    expect(first.path).toBeNull();
    expect(second.path).toBeNull();
    expect(resolution.accept(first.requestId, "/native-signed/sig=stale/path")).toBeNull();
    expect(resolution.accept(second.requestId, "/native-signed/sig=fresh/path")).toBe(
      "/native-signed/sig=fresh/path",
    );
    expect(resolution.reject(first.requestId)).toBe(false);
    expect(resolution.reject(second.requestId)).toBe(true);
  });

  it("makes unsigned requests available immediately", () => {
    const resolution = new NativePathResolution();

    expect(resolution.begin(defaultNativeState).path).toBe(
      "/native-image/w=800/src/images/dog.jpg",
    );
  });
});

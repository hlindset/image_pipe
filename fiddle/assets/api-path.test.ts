import { describe, expect, it } from "vitest";
import {
  defaultApiState,
  ApiPathResolution,
  apiBrowserPath,
  apiFetchPath,
  parseApiTail,
  resolveApiFetchPath,
  resetApiSettings,
} from "./api-path";

describe("API paths", () => {
  it("builds requests with explicit groups and a separate source", () => {
    const state = { ...defaultApiState, options: "w=500/then/trim=fff" };
    expect(apiFetchPath(state)).toBe("/image/w=500/then/trim=fff/src/images/dog.jpg");
    expect(parseApiTail(apiBrowserPath(state).slice("/edit/".length))).toEqual(state);
  });

  it("round trips requests without transform options", () => {
    const state = { ...defaultApiState, options: "" };
    expect(apiFetchPath(state)).toBe("/image/src/images/dog.jpg");
    expect(parseApiTail("src/images/dog.jpg")).toEqual(state);
  });

  for (const [sourceType, source] of [
    ["local", "images/dog.jpg"],
    ["s3", "s3%3A//sources/dog.jpg"],
    ["http", "http%3A//localhost%3A4000/images/dog.jpg"],
  ] as const) {
    it(`round trips the ${sourceType} source through the API URL`, () => {
      const state = { ...defaultApiState, sourceType };
      expect(apiFetchPath(state)).toBe(`/image/w=800/src/${source}`);
      expect(parseApiTail(apiBrowserPath(state).slice("/edit/".length))).toEqual(state);
    });
  }

  it("rejects malformed escapes and sources outside the demo mounts", () => {
    expect(parseApiTail("src/%xx")).toBeNull();
    expect(parseApiTail("src/https%3A//example.com/images/dog.jpg")).toBeNull();
    expect(parseApiTail("src/s3%3A//private/dog.jpg")).toBeNull();
  });

  it("leaves option validation to the API and rejects unknown demo sources", () => {
    expect(parseApiTail("w=oops/src/images/dog.jpg")?.options).toBe("w=oops");
    expect(parseApiTail("w=500/src/private.jpg")).toBeNull();
    expect(parseApiTail("w=500")).toBeNull();
  });

  it("preserves the API source type when resetting transform settings", () => {
    const reset = resetApiSettings({
      ...defaultApiState,
      sourceType: "http",
      options: "w=500/blur=2",
    });

    expect(reset).toEqual({
      ...defaultApiState,
      sourceType: "http",
    });
  });

  it("asks the server for signed and concealed preview paths", async () => {
    const requests: Array<{ tail: string; protection: string }> = [];
    const fetcher = async (_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(JSON.parse(String(init?.body)));
      return new Response(JSON.stringify({ path: "/image-signed/sig=demo/w=64/enc=token" }), {
        headers: { "content-type": "application/json" },
      });
    };
    const state = {
      ...defaultApiState,
      options: "w=64",
      protection: "signed-concealed" as const,
    };

    await expect(resolveApiFetchPath(state, fetcher)).resolves.toBe(
      "/image-signed/sig=demo/w=64/enc=token",
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

    await expect(resolveApiFetchPath(defaultApiState, fetcher)).resolves.toBe(
      "/image/w=800/src/images/dog.jpg",
    );
    expect(called).toBe(false);
  });

  it("keeps protected paths pending and rejects stale helper completions", () => {
    const resolution = new ApiPathResolution();
    const first = resolution.begin({ ...defaultApiState, protection: "signed" });
    const second = resolution.begin({ ...defaultApiState, protection: "signed-concealed" });

    expect(first.path).toBeNull();
    expect(second.path).toBeNull();
    expect(resolution.accept(first.requestId, "/image-signed/sig=stale/path")).toBeNull();
    expect(resolution.accept(second.requestId, "/image-signed/sig=fresh/path")).toBe(
      "/image-signed/sig=fresh/path",
    );
    expect(resolution.reject(first.requestId)).toBe(false);
    expect(resolution.reject(second.requestId)).toBe(true);
  });

  it("makes unsigned requests available immediately", () => {
    const resolution = new ApiPathResolution();

    expect(resolution.begin(defaultApiState).path).toBe("/image/w=800/src/images/dog.jpg");
  });
});

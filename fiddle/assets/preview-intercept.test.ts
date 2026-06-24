import { describe, expect, it } from "vitest";

import { isPreviewUrl, parsePreviewMeta, PREVIEW_PREFIXES } from "./preview-intercept";

describe("isPreviewUrl", () => {
  it("matches all three processing prefixes regardless of query", () => {
    expect(
      isPreviewUrl("http://localhost:4000/img/_/rs:fit:10:10/plain/local:///images/dog.jpg"),
    ).toBe(true);
    expect(isPreviewUrl("http://localhost:4000/iiif-image/dog/full/max/0/default.jpg")).toBe(true);
    expect(isPreviewUrl("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10")).toBe(
      true,
    );
  });

  it("rejects the SPA shell, vite assets, and the display-only /twicpics path", () => {
    expect(isPreviewUrl("http://localhost:4000/")).toBe(false);
    expect(isPreviewUrl("http://localhost:4000/preview-sw.js")).toBe(false);
    expect(isPreviewUrl("http://localhost:5173/main.ts")).toBe(false);
    expect(isPreviewUrl("http://localhost:4000/twicpics/images/dog.jpg?twic=v1/cover=10x10")).toBe(
      false,
    );
  });

  it("returns false for non-URL strings instead of throwing", () => {
    expect(isPreviewUrl("not a url")).toBe(false);
  });

  it("exposes the prefixes as a readonly list", () => {
    expect([...PREVIEW_PREFIXES]).toEqual(["/img/", "/iiif-image/", "/twic/"]);
  });
});

describe("parsePreviewMeta", () => {
  it("accepts a well-formed message", () => {
    const message = parsePreviewMeta({
      type: "preview-meta",
      url: "http://localhost:4000/img/x",
      accept: "image/avif",
      ok: true,
      status: 200,
      statusText: "OK",
      contentType: "image/avif",
      bytes: 1234,
      error: null,
    });
    expect(message).not.toBeNull();
    expect(message?.contentType).toBe("image/avif");
    expect(message?.bytes).toBe(1234);
  });

  it("coerces missing/wrong-typed optional fields to safe defaults", () => {
    const message = parsePreviewMeta({ type: "preview-meta", url: "http://x/img/y" });
    expect(message).toEqual({
      type: "preview-meta",
      url: "http://x/img/y",
      accept: null,
      ok: false,
      status: 0,
      statusText: "",
      contentType: null,
      bytes: null,
      error: null,
    });
  });

  it("rejects foreign messages", () => {
    expect(parsePreviewMeta(null)).toBeNull();
    expect(parsePreviewMeta("hi")).toBeNull();
    expect(parsePreviewMeta({ type: "other", url: "http://x/img/y" })).toBeNull();
    expect(parsePreviewMeta({ type: "preview-meta" })).toBeNull(); // no url
  });
});

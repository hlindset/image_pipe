import { describe, expect, it } from "vitest";
import {
  defaultIiifState,
  iiifIdForSource,
  sourceForIiifId,
  iiifPathTail,
  iiifBrowserPath,
  iiifFetchPath,
  parseIiifTail,
  type IiifState,
} from "./iiif-path";

describe("iiif id derivation", () => {
  it("derives a slash-free, extension-stripped id", () => {
    expect(iiifIdForSource("images/dog.jpg")).toBe("dog");
    expect(iiifIdForSource("images/concert.jpeg")).toBe("concert");
  });

  it("round-trips id -> source -> id", () => {
    const id = iiifIdForSource("images/dog.jpg");
    expect(sourceForIiifId(id)).toBe("images/dog.jpg");
  });

  it("rejects an unknown id", () => {
    expect(sourceForIiifId("nope")).toBeNull();
  });

  it("derives unique ids across all sample images (stem-collision guard)", async () => {
    const { sampleImages } = await import("./processing-path");
    const ids = sampleImages.map((image) => iiifIdForSource(image.path));
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("iiif segment building", () => {
  it("builds the default tail", () => {
    expect(iiifPathTail(defaultIiifState)).toBe("dog/full/max/0/default.jpg");
  });

  it("encodes each region form", () => {
    expect(iiifPathTail({ ...defaultIiifState, region: { kind: "square" } })).toBe(
      "dog/square/max/0/default.jpg",
    );
    expect(
      iiifPathTail({ ...defaultIiifState, region: { kind: "px", x: 0, y: 0, w: 100, h: 100 } }),
    ).toBe("dog/0,0,100,100/max/0/default.jpg");
    expect(
      iiifPathTail({ ...defaultIiifState, region: { kind: "pct", x: 10.5, y: 0, w: 50, h: 50 } }),
    ).toBe("dog/pct:10.5,0,50,50/max/0/default.jpg");
  });

  it("encodes each size form and the upscale flag", () => {
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "w", w: 400 } })).toBe(
      "dog/full/400,/0/default.jpg",
    );
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "h", h: 300 } })).toBe(
      "dog/full/,300/0/default.jpg",
    );
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "wh", w: 400, h: 300 } })).toBe(
      "dog/full/400,300/0/default.jpg",
    );
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "confined", w: 400, h: 300 } })).toBe(
      "dog/full/!400,300/0/default.jpg",
    );
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "pct", n: 50 } })).toBe(
      "dog/full/pct:50/0/default.jpg",
    );
    expect(
      iiifPathTail({ ...defaultIiifState, size: { kind: "pct", n: 200 }, upscale: true }),
    ).toBe("dog/full/^pct:200/0/default.jpg");
  });

  it("encodes rotation, quality, format", () => {
    expect(
      iiifPathTail({
        ...defaultIiifState,
        rotation: { degrees: 90, mirror: false },
        quality: "gray",
        format: "png",
      }),
    ).toBe("dog/full/max/90/gray.png");
  });

  it("builds browser and fetch paths with distinct prefixes", () => {
    expect(iiifBrowserPath(defaultIiifState)).toBe("/iiif/dog/full/max/0/default.jpg");
    expect(iiifFetchPath(defaultIiifState)).toBe("/iiif-image/dog/full/max/0/default.jpg");
  });
});

describe("iiif tail parsing round-trips", () => {
  const cases: IiifState[] = [
    defaultIiifState,
    { ...defaultIiifState, region: { kind: "square" } },
    { ...defaultIiifState, region: { kind: "px", x: 1, y: 2, w: 100, h: 80 } },
    { ...defaultIiifState, region: { kind: "pct", x: 10.5, y: 0, w: 50, h: 50 } },
    { ...defaultIiifState, size: { kind: "w", w: 400 } },
    { ...defaultIiifState, size: { kind: "h", h: 300 } },
    { ...defaultIiifState, size: { kind: "wh", w: 400, h: 300 } },
    { ...defaultIiifState, size: { kind: "confined", w: 400, h: 300 } },
    { ...defaultIiifState, size: { kind: "pct", n: 50 } },
    { ...defaultIiifState, size: { kind: "pct", n: 200 }, upscale: true },
    {
      ...defaultIiifState,
      rotation: { degrees: 270, mirror: false },
      quality: "bitonal",
      format: "webp",
    },
  ];

  for (const state of cases) {
    it(`round-trips ${iiifPathTail(state)}`, () => {
      expect(parseIiifTail(iiifPathTail(state))).toEqual(state);
    });
  }

  it("rejects a malformed tail", () => {
    expect(parseIiifTail("dog/full/max/0")).toBeNull(); // missing quality.format
    expect(parseIiifTail("nope/full/max/0/default.jpg")).toBeNull(); // unknown id
    expect(parseIiifTail("dog/full/!400,300,5/0/default.jpg")).toBeNull(); // confined extra comma
  });

  it("parses arbitrary + mirror rotation", () => {
    expect(parseIiifTail("dog/full/max/45/default.jpg")?.rotation ?? null).toEqual({
      degrees: 45,
      mirror: false,
    });
    expect(parseIiifTail("dog/full/max/!90/default.jpg")?.rotation ?? null).toEqual({
      degrees: 90,
      mirror: true,
    });
    expect(parseIiifTail("dog/full/max/370/default.jpg")).toBeNull(); // out of range
  });
});

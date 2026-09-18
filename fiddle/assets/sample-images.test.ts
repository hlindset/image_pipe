import { describe, expect, it } from "vitest";

import { sampleImages } from "virtual:sample-images";

describe("sample image virtual module", () => {
  it("lists fiddle images with usable compile-time metadata", () => {
    expect(sampleImages.length).toBeGreaterThan(0);
    expect(sampleImages.map((image) => image.path)).toEqual(
      [...sampleImages].map((image) => image.path).sort((left, right) => left.localeCompare(right)),
    );

    for (const image of sampleImages) {
      expect(image.path).toMatch(/^images\/.+\.(avif|jpe?g|png|webp)$/);
      expect(image.label).toBe(image.path.replace(/^images\//, ""));
      expect(image.width).toBeGreaterThan(0);
      expect(image.height).toBeGreaterThan(0);
    }

    expect(sampleImages).toContainEqual({
      path: "images/dog.jpg",
      label: "dog.jpg",
      width: 5011,
      height: 7516,
    });
    expect(sampleImages).toContainEqual({
      path: "images/orientation-6.jpg",
      label: "orientation-6.jpg",
      width: 96,
      height: 64,
    });
    expect(sampleImages.map((image) => image.path)).not.toContain("images/waterfall.jpg");
  });
});

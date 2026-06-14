import { describe, expect, it } from "vitest";
import { defaultFiddleState } from "./processing-path";
import { defaultIiifState } from "./iiif-path";
import { defaultTwicPicsState } from "./twicpics-path";
import { appPathForState, parseAppPath, type AppState } from "./fiddle-url-state";

function baseAppState(): AppState {
  return {
    provider: "imgproxy",
    imgproxy: { ...defaultFiddleState },
    iiif: { ...defaultIiifState },
    twicpics: { ...defaultTwicPicsState },
  };
}

describe("appPathForState", () => {
  it("prefixes the imgproxy signed path", () => {
    expect(appPathForState(baseAppState())).toBe("/imgproxy/plain/local:///images/dog.jpg");
  });

  it("emits the IIIF browser path when the provider is iiif", () => {
    const state: AppState = { ...baseAppState(), provider: "iiif" };
    expect(appPathForState(state)).toBe("/iiif/dog/full/max/0/default.jpg");
  });
});

describe("parseAppPath dispatch", () => {
  it("routes an imgproxy-prefixed path to the imgproxy slice", () => {
    const parsed = parseAppPath("/imgproxy/rs:fill:200:200:0/plain/local:///images/dog.jpg");
    expect(parsed.provider).toBe("imgproxy");
    expect(parsed.imgproxy.resizeEnabled).toBe(true);
    expect(parsed.imgproxy.width).toBe(200);
  });

  it("routes an iiif-prefixed path to the iiif slice", () => {
    const parsed = parseAppPath("/iiif/dog/0,0,100,100/50,/90/gray.png");
    expect(parsed.provider).toBe("iiif");
    expect(parsed.iiif.region).toEqual({ kind: "px", x: 0, y: 0, w: 100, h: 100 });
    expect(parsed.iiif.size).toEqual({ kind: "w", w: 50 });
    expect(parsed.iiif.rotation).toEqual({ degrees: 90, mirror: false });
  });

  it("defaults to imgproxy for root or unknown prefix", () => {
    expect(parseAppPath("/").provider).toBe("imgproxy");
    expect(parseAppPath("/g:sm/plain/local:///images/dog.jpg").provider).toBe("imgproxy");
    expect(parseAppPath("/g:sm/plain/local:///images/dog.jpg").imgproxy.gravityEnabled).toBe(false);
  });

  it("stays on the iiif provider for a malformed iiif tail, with a default slice", () => {
    const parsed = parseAppPath("/iiif/garbage");
    expect(parsed.provider).toBe("iiif");
    expect(parsed.iiif).toEqual(defaultIiifState);
  });

  it("does not leak the inactive slice into the active URL", () => {
    const state: AppState = {
      provider: "iiif",
      imgproxy: { ...defaultFiddleState, resizeEnabled: true, width: 999 },
      iiif: { ...defaultIiifState },
      twicpics: { ...defaultTwicPicsState },
    };
    const url = appPathForState(state);
    expect(url.startsWith("/iiif/")).toBe(true);
    expect(url).not.toContain("999");
    expect(url).not.toContain("plain");
  });
});

describe("twicpics provider dispatch", () => {
  it("emits the twicpics browser path when the provider is twicpics", () => {
    const state: AppState = {
      ...baseAppState(),
      provider: "twicpics",
      twicpics: {
        ...defaultTwicPicsState,
        chain: [
          { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        ],
      },
    };
    expect(appPathForState(state)).toBe(
      "/twicpics/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80",
    );
  });

  it("routes a twicpics-prefixed path + search to the twicpics slice", () => {
    const parsed = parseAppPath(
      "/twicpics/images/dog.jpg",
      "?twic=v1/resize=340/resize=50p/output=webp/quality=70",
    );
    expect(parsed.provider).toBe("twicpics");
    expect(parsed.twicpics.chain.map((s) => s.type)).toEqual(["resize", "resize"]);
    expect(parsed.twicpics.output).toBe("webp");
    expect(parsed.twicpics.quality).toBe(70);
  });

  it("stays on the twicpics provider for a malformed tail, with a default slice", () => {
    const parsed = parseAppPath("/twicpics/images/dog.jpg", "?twic=v1/zoom=2");
    expect(parsed.provider).toBe("twicpics");
    expect(parsed.twicpics).toEqual(defaultTwicPicsState);
  });
});

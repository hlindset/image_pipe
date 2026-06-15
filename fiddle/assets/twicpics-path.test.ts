import { describe, expect, it } from "vitest";
import {
  defaultStep,
  defaultTwicPicsState,
  parseTwicTail,
  setResizeAxisUnit,
  stepSummary,
  stepToken,
  twicBrowserPath,
  twicFetchPath,
  twicParam,
  type TransformStep,
  type TwicPicsState,
} from "./twicpics-path";

describe("twicpics step token encoding", () => {
  it("encodes resize dimensions and units", () => {
    expect(
      stepToken({
        type: "resize",
        id: "x",
        w: { unit: "px", value: 340 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("resize=340");
    expect(
      stepToken({
        type: "resize",
        id: "x",
        w: { unit: "p", value: 50 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("resize=50p");
    expect(
      stepToken({
        type: "resize",
        id: "x",
        w: { unit: "s", value: 0.5 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("resize=0.5s");
    expect(
      stepToken({
        type: "resize",
        id: "x",
        w: { unit: "px", value: 340 },
        h: { unit: "px", value: 200 },
      }),
    ).toBe("resize=340x200");
    expect(
      stepToken({
        type: "resize",
        id: "x",
        w: { unit: "auto", value: 0 },
        h: { unit: "px", value: 200 },
      }),
    ).toBe("resize=-x200");
  });

  it("encodes cover size and ratio", () => {
    expect(stepToken({ type: "cover", id: "x", mode: "size", w: 100, h: 100 })).toBe(
      "cover=100x100",
    );
    expect(stepToken({ type: "cover", id: "x", mode: "ratio", w: 16, h: 9 })).toBe("cover=16:9");
  });

  it("encodes contain and inside", () => {
    expect(stepToken({ type: "contain", id: "x", w: 200, h: 200 })).toBe("contain=200x200");
    expect(stepToken({ type: "inside", id: "x", w: 200, h: 200 })).toBe("inside=200x200");
  });

  it("encodes crop with and without an origin", () => {
    expect(stepToken({ type: "crop", id: "x", w: 200, h: 150, origin: null })).toBe("crop=200x150");
    expect(stepToken({ type: "crop", id: "x", w: 200, h: 150, origin: { x: 10, y: 20 } })).toBe(
      "crop=200x150@10x20",
    );
  });

  it("encodes focus anchors", () => {
    expect(stepToken({ type: "focus", id: "x", anchor: "top" })).toBe("focus=top");
    expect(stepToken({ type: "focus", id: "x", anchor: "bottom-right" })).toBe(
      "focus=bottom-right",
    );
  });
});

describe("twicpics manipulation param", () => {
  it("builds v1 with output and quality for an empty chain", () => {
    expect(twicParam(defaultTwicPicsState)).toBe("v1/output=auto/quality=80");
  });

  it("preserves chain order in the param", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "2", anchor: "top-left" },
        { type: "resize", id: "3", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
      ],
    };
    expect(twicParam(state)).toBe("v1/resize=340/focus=top-left/resize=50p/output=auto/quality=80");
  });

  it("emits explicit output and quality", () => {
    expect(twicParam({ ...defaultTwicPicsState, output: "webp", quality: 65 })).toBe(
      "v1/output=webp/quality=65",
    );
  });
});

describe("twicpics fetch and browser paths", () => {
  it("uses /twic for fetch and /twicpics for the browser, source in the path", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
      ],
    };
    expect(twicFetchPath(state)).toBe(
      "/twic/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80",
    );
    expect(twicBrowserPath(state)).toBe(
      "/twicpics/images/dog.jpg?twic=v1/resize=340/output=auto/quality=80",
    );
  });
});

describe("defaultStep factory", () => {
  it("produces a parser-acceptable token for each transform type", () => {
    const types: TransformStep["type"][] = [
      "resize",
      "cover",
      "contain",
      "inside",
      "crop",
      "focus",
    ];
    for (const type of types) {
      const created = defaultStep(type, `id-${type}`);
      expect(created.type).toBe(type);
      expect(created.id).toBe(`id-${type}`);
      expect(stepToken(created)).toContain(`${type}=`);
    }
  });
});

describe("stepSummary", () => {
  it("formats a resize with px width and auto height", () => {
    expect(
      stepSummary({
        type: "resize",
        id: "x",
        w: { unit: "px", value: 340 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("340px × auto");
  });

  it("formats a cover in ratio mode", () => {
    expect(stepSummary({ type: "cover", id: "x", mode: "ratio", w: 16, h: 9 })).toBe("16:9");
  });

  it("formats a cover in size mode", () => {
    expect(stepSummary({ type: "cover", id: "x", mode: "size", w: 100, h: 100 })).toBe("100×100");
  });

  it("formats a crop with an origin", () => {
    expect(stepSummary({ type: "crop", id: "x", w: 200, h: 150, origin: { x: 10, y: 20 } })).toBe(
      "200×150 @ 10,20",
    );
  });

  it("formats a focus by anchor name", () => {
    expect(stepSummary({ type: "focus", id: "x", anchor: "top-left" })).toBe("top-left");
  });
});

describe("setResizeAxisUnit", () => {
  it("never leaves both resize axes auto (which would emit resize=-)", () => {
    const step: Extract<TransformStep, { type: "resize" }> = {
      type: "resize",
      id: "1",
      w: { unit: "px", value: 300 },
      h: { unit: "auto", value: 0 },
    };
    setResizeAxisUnit(step, "w", "auto");
    const autoCount = [step.w.unit, step.h.unit].filter((unit) => unit === "auto").length;
    expect(autoCount).toBeLessThan(2);
    expect(stepToken(step)).not.toBe("resize=-");
  });

  it("preserves a positive value when switching units", () => {
    const step: Extract<TransformStep, { type: "resize" }> = {
      type: "resize",
      id: "1",
      w: { unit: "px", value: 250 },
      h: { unit: "auto", value: 0 },
    };
    setResizeAxisUnit(step, "w", "p");
    expect(step.w).toEqual({ unit: "p", value: 250 });
  });
});

// Chain ids are session-local (never serialized), so round-trip comparisons drop
// them: the URL preserves order + params, not the synthetic id.
function stripIds(state: TwicPicsState) {
  return { ...state, chain: state.chain.map(({ id: _id, ...rest }) => rest) };
}

// Build the location.search string the SPA would read back for a given state.
function searchFor(state: TwicPicsState): string {
  return `?twic=${twicParam(state)}`;
}

describe("twicpics round-trips (browser path -> state)", () => {
  const cases: TwicPicsState[] = [
    defaultTwicPicsState,
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
      ],
    },
    // the relative-unit showcase: order matters; percents resolve against the running image
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "resize", id: "2", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "px", value: 200 } },
        { type: "resize", id: "2", w: { unit: "auto", value: 0 }, h: { unit: "px", value: 100 } },
        { type: "resize", id: "3", w: { unit: "s", value: 0.5 }, h: { unit: "auto", value: 0 } },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        { type: "focus", id: "1", anchor: "top-left" },
        { type: "cover", id: "2", mode: "size", w: 100, h: 100 },
      ],
    },
    { ...defaultTwicPicsState, chain: [{ type: "cover", id: "1", mode: "ratio", w: 16, h: 9 }] },
    { ...defaultTwicPicsState, chain: [{ type: "contain", id: "1", w: 200, h: 200 }] },
    { ...defaultTwicPicsState, chain: [{ type: "inside", id: "1", w: 200, h: 200 }] },
    { ...defaultTwicPicsState, chain: [{ type: "crop", id: "1", w: 200, h: 150, origin: null }] },
    {
      ...defaultTwicPicsState,
      chain: [{ type: "crop", id: "1", w: 200, h: 150, origin: { x: 10, y: 20 } }],
    },
    { ...defaultTwicPicsState, output: "avif", quality: 50 },
    {
      ...defaultTwicPicsState,
      source: "images/beach.jpg",
      chain: [
        { type: "resize", id: "1", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "2", anchor: "top-left" },
      ],
      output: "png",
      quality: 90,
    },
  ];

  for (const state of cases) {
    it(`round-trips ${twicParam(state)}`, () => {
      const parsed = parseTwicTail(state.source, searchFor(state));
      expect(parsed).not.toBeNull();
      expect(stripIds(parsed!)).toEqual(stripIds(state));
    });
  }

  it("preserves a long chain order exactly", () => {
    const state: TwicPicsState = {
      ...defaultTwicPicsState,
      chain: [
        { type: "resize", id: "1", w: { unit: "px", value: 340 }, h: { unit: "auto", value: 0 } },
        { type: "resize", id: "2", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "3", anchor: "top-left" },
        { type: "cover", id: "4", mode: "size", w: 100, h: 100 },
        { type: "crop", id: "5", w: 80, h: 80, origin: null },
      ],
    };
    const parsed = parseTwicTail(state.source, searchFor(state));
    expect(parsed!.chain.map((s) => s.type)).toEqual([
      "resize",
      "resize",
      "focus",
      "cover",
      "crop",
    ]);
  });

  it("assigns a non-empty, unique id to every parsed step", () => {
    const parsed = parseTwicTail(
      "images/dog.jpg",
      "?twic=v1/resize=340/resize=50p/output=auto/quality=80",
    );
    const ids = parsed!.chain.map((s) => s.id);
    expect(ids).toHaveLength(2);
    expect(new Set(ids).size).toBe(2);
    expect(ids.every((id) => id.length > 0)).toBe(true);
  });
});

describe("twicpics parse rejection", () => {
  it("rejects an unknown source", () => {
    expect(parseTwicTail("images/nope.jpg", "?twic=v1/output=auto/quality=80")).toBeNull();
  });

  it("rejects a missing v1 prefix", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v2/resize=340")).toBeNull();
  });

  it("rejects an unsupported transform", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/zoom=2")).toBeNull();
  });

  it("rejects an unsupported focus anchor (no center)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=center")).toBeNull();
  });

  it("rejects a malformed segment without '='", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/resize")).toBeNull();
  });

  it("rejects an out-of-range quality", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/quality=0")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/quality=101")).toBeNull();
  });

  it("rejects an unsupported output format", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/output=heif")).toBeNull();
  });

  it("returns an empty chain for a valid source with no twic param", () => {
    const parsed = parseTwicTail("images/dog.jpg", "");
    expect(parsed).not.toBeNull();
    expect(parsed!.chain).toEqual([]);
    expect(parsed!.output).toBe("auto");
    expect(parsed!.quality).toBe(80);
  });
});

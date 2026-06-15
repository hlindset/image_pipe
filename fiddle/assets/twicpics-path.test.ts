import { describe, expect, it } from "vitest";
import {
  defaultStep,
  defaultTwicPicsState,
  parseTwicTail,
  setDimAxisUnit,
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

  it("encodes cover size (px/%/scale/auto) and ratio", () => {
    expect(
      stepToken({
        type: "cover",
        id: "x",
        mode: "size",
        w: { unit: "px", value: 100 },
        h: { unit: "px", value: 100 },
      }),
    ).toBe("cover=100x100");
    expect(
      stepToken({
        type: "cover",
        id: "x",
        mode: "size",
        w: { unit: "p", value: 50 },
        h: { unit: "s", value: 0.5 },
      }),
    ).toBe("cover=50px0.5s");
    expect(
      stepToken({
        type: "cover",
        id: "x",
        mode: "size",
        w: { unit: "px", value: 200 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("cover=200");
    expect(stepToken({ type: "cover", id: "x", mode: "ratio", w: 16, h: 9 })).toBe("cover=16:9");
  });

  it("encodes contain (px/%/scale/auto) and inside (px-only)", () => {
    expect(
      stepToken({
        type: "contain",
        id: "x",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 200 },
      }),
    ).toBe("contain=200x200");
    expect(
      stepToken({
        type: "contain",
        id: "x",
        w: { unit: "p", value: 75 },
        h: { unit: "s", value: 2 },
      }),
    ).toBe("contain=75px2s");
    expect(
      stepToken({
        type: "contain",
        id: "x",
        w: { unit: "auto", value: 0 },
        h: { unit: "px", value: 150 },
      }),
    ).toBe("contain=-x150");
    expect(stepToken({ type: "inside", id: "x", mode: "size", w: 200, h: 200 })).toBe(
      "inside=200x200",
    );
    expect(stepToken({ type: "inside", id: "x", mode: "ratio", w: 4, h: 3 })).toBe("inside=4:3");
  });

  it("encodes crop with and without an origin", () => {
    expect(
      stepToken({
        type: "crop",
        id: "x",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 150 },
        origin: null,
      }),
    ).toBe("crop=200x150");
    expect(
      stepToken({
        type: "crop",
        id: "x",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 150 },
        origin: { x: { unit: "px", value: 10 }, y: { unit: "px", value: 20 } },
      }),
    ).toBe("crop=200x150@10x20");
  });

  it("encodes crop with relative size and a zero-based origin", () => {
    expect(
      stepToken({
        type: "crop",
        id: "x",
        w: { unit: "p", value: 50 },
        h: { unit: "s", value: 0.5 },
        origin: { x: { unit: "px", value: 0 }, y: { unit: "px", value: 0 } },
      }),
    ).toBe("crop=50px0.5s@0x0");
    expect(
      stepToken({
        type: "crop",
        id: "x",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 150 },
        origin: { x: { unit: "p", value: 25 }, y: { unit: "s", value: 0.1 } },
      }),
    ).toBe("crop=200x150@25px0.1s");
  });

  it("encodes focus anchors", () => {
    expect(stepToken({ type: "focus", id: "x", mode: "anchor", anchor: "top" })).toBe("focus=top");
    expect(stepToken({ type: "focus", id: "x", mode: "anchor", anchor: "bottom-right" })).toBe(
      "focus=bottom-right",
    );
  });

  it("encodes a relative coordinate focus (no bare pixels)", () => {
    expect(
      stepToken({
        type: "focus",
        id: "x",
        mode: "coord",
        x: { unit: "p", value: 30 },
        y: { unit: "p", value: 70 },
      }),
    ).toBe("focus=30px70p");
    expect(
      stepToken({
        type: "focus",
        id: "x",
        mode: "coord",
        x: { unit: "s", value: 0.25 },
        y: { unit: "s", value: 0.75 },
      }),
    ).toBe("focus=0.25sx0.75s");
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
        { type: "focus", id: "2", mode: "anchor", anchor: "top-left" },
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
    expect(
      stepSummary({
        type: "cover",
        id: "x",
        mode: "size",
        w: { unit: "px", value: 100 },
        h: { unit: "px", value: 100 },
      }),
    ).toBe("100px × 100px");
  });

  it("formats a cover in size mode with relative units and auto", () => {
    expect(
      stepSummary({
        type: "cover",
        id: "x",
        mode: "size",
        w: { unit: "p", value: 50 },
        h: { unit: "auto", value: 0 },
      }),
    ).toBe("50% × auto");
  });

  it("formats an inside in size mode (px)", () => {
    expect(stepSummary({ type: "inside", id: "x", mode: "size", w: 200, h: 200 })).toBe("200×200");
  });

  it("formats an inside in ratio mode", () => {
    expect(stepSummary({ type: "inside", id: "x", mode: "ratio", w: 4, h: 3 })).toBe("4:3");
  });

  it("formats a contain with relative units", () => {
    expect(
      stepSummary({
        type: "contain",
        id: "x",
        w: { unit: "s", value: 0.5 },
        h: { unit: "px", value: 200 },
      }),
    ).toBe("0.5s × 200px");
  });

  it("formats a crop with an origin", () => {
    expect(
      stepSummary({
        type: "crop",
        id: "x",
        w: { unit: "px", value: 200 },
        h: { unit: "px", value: 150 },
        origin: { x: { unit: "px", value: 10 }, y: { unit: "px", value: 20 } },
      }),
    ).toBe("200px×150px @ 10px,20px");
  });

  it("formats a crop with relative size and a zero origin", () => {
    expect(
      stepSummary({
        type: "crop",
        id: "x",
        w: { unit: "p", value: 50 },
        h: { unit: "s", value: 0.5 },
        origin: { x: { unit: "px", value: 0 }, y: { unit: "px", value: 0 } },
      }),
    ).toBe("50%×0.5s @ 0px,0px");
  });

  it("formats a focus by anchor name", () => {
    expect(stepSummary({ type: "focus", id: "x", mode: "anchor", anchor: "top-left" })).toBe(
      "top-left",
    );
  });

  it("formats a relative coordinate focus", () => {
    expect(
      stepSummary({
        type: "focus",
        id: "x",
        mode: "coord",
        x: { unit: "p", value: 30 },
        y: { unit: "p", value: 70 },
      }),
    ).toBe("30%,70%");
  });
});

describe("setDimAxisUnit", () => {
  it("never leaves both resize axes auto (which would emit resize=-)", () => {
    const step: Extract<TransformStep, { type: "resize" }> = {
      type: "resize",
      id: "1",
      w: { unit: "px", value: 300 },
      h: { unit: "auto", value: 0 },
    };
    setDimAxisUnit(step, "w", "auto");
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
    setDimAxisUnit(step, "w", "p");
    expect(step.w).toEqual({ unit: "p", value: 250 });
  });

  it("guards both-auto on a cover-size step and keeps it round-trippable", () => {
    const step: Extract<TransformStep, { type: "cover"; mode: "size" }> = {
      type: "cover",
      id: "1",
      mode: "size",
      w: { unit: "px", value: 200 },
      h: { unit: "auto", value: 0 },
    };
    setDimAxisUnit(step, "w", "auto");
    const autoCount = [step.w.unit, step.h.unit].filter((unit) => unit === "auto").length;
    expect(autoCount).toBeLessThan(2);
    expect(stepToken(step)).not.toBe("cover=-");
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
        { type: "focus", id: "1", mode: "anchor", anchor: "top-left" },
        {
          type: "cover",
          id: "2",
          mode: "size",
          w: { unit: "px", value: 100 },
          h: { unit: "px", value: 100 },
        },
      ],
    },
    // cover size with relative units (% width, scale height)
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "cover",
          id: "1",
          mode: "size",
          w: { unit: "p", value: 50 },
          h: { unit: "s", value: 0.5 },
        },
      ],
    },
    // cover size with a single (auto-height) axis
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "cover",
          id: "1",
          mode: "size",
          w: { unit: "px", value: 200 },
          h: { unit: "auto", value: 0 },
        },
      ],
    },
    { ...defaultTwicPicsState, chain: [{ type: "cover", id: "1", mode: "ratio", w: 16, h: 9 }] },
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "contain",
          id: "1",
          w: { unit: "px", value: 200 },
          h: { unit: "px", value: 200 },
        },
      ],
    },
    // contain with relative units and an auto width
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "contain",
          id: "1",
          w: { unit: "auto", value: 0 },
          h: { unit: "p", value: 75 },
        },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [{ type: "inside", id: "1", mode: "size", w: 200, h: 200 }],
    },
    { ...defaultTwicPicsState, chain: [{ type: "inside", id: "1", mode: "ratio", w: 4, h: 3 }] },
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "crop",
          id: "1",
          w: { unit: "px", value: 200 },
          h: { unit: "px", value: 150 },
          origin: null,
        },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "crop",
          id: "1",
          w: { unit: "px", value: 200 },
          h: { unit: "px", value: 150 },
          origin: { x: { unit: "px", value: 10 }, y: { unit: "px", value: 20 } },
        },
      ],
    },
    // relative crop size + zero-based origin
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "crop",
          id: "1",
          w: { unit: "p", value: 50 },
          h: { unit: "s", value: 0.5 },
          origin: { x: { unit: "px", value: 0 }, y: { unit: "px", value: 0 } },
        },
      ],
    },
    // relative-unit origin coordinates
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "crop",
          id: "1",
          w: { unit: "px", value: 200 },
          h: { unit: "px", value: 150 },
          origin: { x: { unit: "p", value: 25 }, y: { unit: "s", value: 0.1 } },
        },
      ],
    },
    // relative coordinate focus (percent and scale)
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "focus",
          id: "1",
          mode: "coord",
          x: { unit: "p", value: 30 },
          y: { unit: "p", value: 70 },
        },
      ],
    },
    {
      ...defaultTwicPicsState,
      chain: [
        {
          type: "focus",
          id: "1",
          mode: "coord",
          x: { unit: "s", value: 0.25 },
          y: { unit: "s", value: 0.75 },
        },
      ],
    },
    { ...defaultTwicPicsState, output: "avif", quality: 50 },
    {
      ...defaultTwicPicsState,
      source: "images/beach.jpg",
      chain: [
        { type: "resize", id: "1", w: { unit: "p", value: 50 }, h: { unit: "auto", value: 0 } },
        { type: "focus", id: "2", mode: "anchor", anchor: "top-left" },
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
        { type: "focus", id: "3", mode: "anchor", anchor: "top-left" },
        {
          type: "cover",
          id: "4",
          mode: "size",
          w: { unit: "px", value: 100 },
          h: { unit: "px", value: 100 },
        },
        {
          type: "crop",
          id: "5",
          w: { unit: "px", value: 80 },
          h: { unit: "px", value: 80 },
          origin: null,
        },
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

  it("rejects focus=auto (parser-rejected, not emittable)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=auto")).toBeNull();
  });

  it("rejects bare-pixel focus coordinates (relative units only)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=100x200")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=100px200")).toBeNull();
  });

  it("rejects an out-of-range relative focus coordinate (ratio > 1)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=150px50p")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=0.5sx2s")).toBeNull();
  });

  it("accepts in-range relative focus coordinates", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=30px70p")).not.toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/focus=100px0p")).not.toBeNull();
  });

  it("accepts a zero-based crop origin and rejects a zero crop size", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/crop=200x150@0x0")).not.toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/crop=0x150")).toBeNull();
  });

  it("accepts relative units for cover (size mode) and contain", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/cover=50px0.5s")).not.toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/contain=75px2s")).not.toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/cover=200")).not.toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/contain=-x150")).not.toBeNull();
  });

  it("rejects relative units for inside size (pixels-only, mirroring the parser)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/inside=50px100")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/inside=100x0.5s")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/inside=100")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/inside=-x100")).toBeNull();
  });

  it("parses inside=W:H as ratio mode and inside=WxH as px size mode", () => {
    const ratio = parseTwicTail("images/dog.jpg", "?twic=v1/inside=4:3");
    expect(ratio).not.toBeNull();
    expect(ratio!.chain[0]).toMatchObject({ type: "inside", mode: "ratio", w: 4, h: 3 });

    const size = parseTwicTail("images/dog.jpg", "?twic=v1/inside=100x80");
    expect(size).not.toBeNull();
    expect(size!.chain[0]).toMatchObject({ type: "inside", mode: "size", w: 100, h: 80 });
  });

  it("parseDimPair refuses a degenerate both-auto cover/contain (UI round-trip guard)", () => {
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/cover=-")).toBeNull();
    expect(parseTwicTail("images/dog.jpg", "?twic=v1/contain=-x-")).toBeNull();
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

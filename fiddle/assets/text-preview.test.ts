import { describe, expect, it } from "vitest";
import { isTextPreview, readTextPreview } from "./text-preview";

describe("text terminal preview", () => {
  it("recognizes API terminals only before the source separator", () => {
    expect(isTextPreview("/image/output=info/src/images/dog.jpg")).toBe(true);
    expect(isTextPreview("/image/w=20/output=blurhash/src/images/dog.jpg")).toBe(true);
    expect(isTextPreview("/image-signed/sig=value/output=info/enc/token")).toBe(true);
    expect(isTextPreview("/image/src/output=info/dog.jpg")).toBe(false);
    expect(isTextPreview("/image/w=20/src/images/dog.jpg")).toBe(false);
  });

  it("pretty prints JSON while measuring the original response bytes", async () => {
    const body = '{"width":24,"height":16}';
    const preview = await readTextPreview(
      new Response(body, {
        headers: { "content-type": "application/json; charset=utf-8", "x-imagepipe-cache": "miss" },
      }),
    );
    expect(preview.text).toBe(JSON.stringify(JSON.parse(body), null, 2));
    expect(preview.bytes).toBe(body.length);
    expect(preview.contentType).toBe("application/json");
    expect(preview.debugHeaders).toEqual({ "x-imagepipe-cache": "miss" });
  });

  it("preserves plain text and surfaces server errors", async () => {
    const preview = await readTextPreview(
      new Response("LEHV6nWB2yk8", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      }),
    );
    expect(preview.text).toBe("LEHV6nWB2yk8");
    await expect(readTextPreview(new Response("Invalid option", { status: 400 }))).rejects.toThrow(
      "400: Invalid option",
    );
  });
});

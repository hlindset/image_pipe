import { afterEach, describe, expect, it, vi } from "vitest";

import { debouncePreviewPath } from "./preview-metadata";

describe("debouncePreviewPath", () => {
  afterEach(() => vi.useRealTimers());

  it("cancels pending unsigned work when a protected request becomes pending", () => {
    vi.useFakeTimers();
    const seen: string[] = [];
    const schedule = debouncePreviewPath((path) => seen.push(path), 150);

    schedule("/native-image/w=64/src/images/dog.jpg");
    schedule(null);
    vi.advanceTimersByTime(150);

    expect(seen).toEqual([]);
  });
});

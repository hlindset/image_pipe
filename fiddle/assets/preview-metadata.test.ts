import { afterEach, describe, expect, it, vi } from "vitest";

import { debounce, debouncePreviewPath } from "./preview-metadata";

describe("debouncePreviewPath", () => {
  afterEach(() => vi.useRealTimers());

  it("cancels queued preview and location work when their effects are disposed", () => {
    vi.useFakeTimers();
    const preview = vi.fn();
    const location = vi.fn();
    const schedulePreview = debouncePreviewPath(preview, 150);
    const scheduleLocation = debounce(location, 150);

    const disposePreview = schedulePreview("/image/output=info/src/images/dog.jpg");
    const disposeLocation = scheduleLocation("/edit/output=info/src/images/dog.jpg");
    disposePreview();
    disposeLocation();
    vi.runAllTimers();

    expect(preview).not.toHaveBeenCalled();
    expect(location).not.toHaveBeenCalled();
  });

  it("a previous cleanup does not cancel a newer preview", () => {
    vi.useFakeTimers();
    const preview = vi.fn();
    const schedule = debouncePreviewPath(preview, 150);
    const disposePrevious = schedule("/image/w=64/src/images/dog.jpg");
    schedule("/image/w=128/src/images/dog.jpg");
    disposePrevious();
    vi.runAllTimers();

    expect(preview).toHaveBeenCalledExactlyOnceWith("/image/w=128/src/images/dog.jpg");
  });

  it("cancels pending unsigned work when a protected request becomes pending", () => {
    vi.useFakeTimers();
    const seen: string[] = [];
    const schedule = debouncePreviewPath((path) => seen.push(path), 150);

    schedule("/image/w=64/src/images/dog.jpg");
    schedule(null);
    vi.advanceTimersByTime(150);

    expect(seen).toEqual([]);
  });
});

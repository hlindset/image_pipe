import { describe, expect, it } from "vitest";
import { imagePreviewUrl } from "./preview-metadata";

import {
  PREVIEW_WORKER_URL,
  PreviewMetadataTracker,
  registerPreviewWorker,
} from "./preview-bridge";

const meta = (over: Partial<Parameters<PreviewMetadataTracker["applyMessage"]>[0]> = {}) => ({
  type: "preview-meta" as const,
  url: "http://localhost:4000/image/w=10/src/images/dog.jpg",
  accept: "image/avif",
  ok: true,
  status: 200,
  statusText: "OK",
  contentType: "image/webp",
  bytes: 4321,
  error: null,
  debugHeaders: null,
  ...over,
});

describe("PreviewMetadataTracker", () => {
  it("ignores a delayed error after returning to the same image URL", () => {
    const tracker = new PreviewMetadataTracker();
    const canonical = "http://localhost:4000/image/w=10/src/images/dog.jpg";
    const first = imagePreviewUrl(canonical);
    tracker.begin(first);
    tracker.begin(imagePreviewUrl("http://localhost:4000/image/w=20/src/images/dog.jpg"));
    const current = imagePreviewUrl(canonical);
    const currentId = tracker.begin(current);
    tracker.applyDimensions({ width: 10, height: 15 }, currentId);
    tracker.applyMessage(meta({ url: current, bytes: 123 }));

    tracker.applyMessage(meta({ url: first, ok: false, status: 503, statusText: "Unavailable" }));

    expect(tracker.error).toBeNull();
    expect(tracker.metadata?.bytes).toBe(123);
    const serverUrl = new URL(current);
    serverUrl.hash = "";
    expect(serverUrl.href).toBe(canonical);
  });

  it("yields null metadata until dimensions arrive, then merges SW bytes/contentType", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/w=10/src/images/dog.jpg");

    // SW message arrives before onload: stashed, not yet renderable (needs dimensions).
    t.applyMessage(meta());
    expect(t.metadata).toBeNull();
    expect(t.error).toBeNull();

    t.applyDimensions({ width: 10, height: 10 }, id);
    expect(t.metadata).toEqual({
      width: 10,
      height: 10,
      bytes: 4321,
      contentType: "image/webp",
      debugHeaders: null,
    });
  });

  it("merges when the SW message arrives AFTER onload", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/src/images/dog.jpg");
    t.applyDimensions({ width: 5, height: 7 }, id);
    expect(t.metadata).toEqual({
      width: 5,
      height: 7,
      bytes: null,
      contentType: null,
      debugHeaders: null,
    });

    t.applyMessage(
      meta({
        url: "http://localhost:4000/image/src/images/dog.jpg",
        bytes: 99,
        contentType: "image/avif",
      }),
    );
    expect(t.metadata).toEqual({
      width: 5,
      height: 7,
      bytes: 99,
      contentType: "image/avif",
      debugHeaders: null,
    });
  });

  it("drops a message whose url does not match the in-flight preview", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/w=10/src/images/dog.jpg");
    t.applyDimensions({ width: 10, height: 10 }, id);
    t.applyMessage(meta({ url: "http://localhost:4000/image/w=20/src/images/dog.jpg" }));
    expect(t.metadata?.bytes).toBeNull();
  });

  it("merges an ok message that carries null bytes/contentType", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/src/images/dog.jpg");
    t.applyDimensions({ width: 3, height: 4 }, id);
    t.applyMessage(
      meta({
        url: "http://localhost:4000/image/src/images/dog.jpg",
        bytes: null,
        contentType: null,
      }),
    );
    expect(t.metadata).toEqual({
      width: 3,
      height: 4,
      bytes: null,
      contentType: null,
      debugHeaders: null,
    });
  });

  it("threads debugHeaders from the SW message onto the metadata", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/src/images/dog.jpg");
    t.applyDimensions({ width: 5, height: 7 }, id);
    t.applyMessage(
      meta({
        url: "http://localhost:4000/image/src/images/dog.jpg",
        debugHeaders: { "x-imagepipe-cache": "miss" },
      }),
    );
    expect(t.metadata).toEqual({
      width: 5,
      height: 7,
      bytes: 4321,
      contentType: "image/webp",
      debugHeaders: { "x-imagepipe-cache": "miss" },
    });
  });

  it("keeps error terminal: dimensions arriving after a non-ok message do not revive metadata", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/image/src/images/dog.jpg");
    t.applyMessage(
      meta({
        url: "http://localhost:4000/image/src/images/dog.jpg",
        ok: false,
        status: 415,
        statusText: "Unsupported Media Type",
        bytes: null,
        error: null,
      }),
    );
    t.applyDimensions({ width: 9, height: 9 }, id); // would normally produce metadata
    expect(t.metadata).toBeNull();
    expect(t.error).toBe("415 Unsupported Media Type");
  });

  it("records an error from a non-ok SW message", () => {
    const t = new PreviewMetadataTracker();
    t.begin("http://localhost:4000/image/src/images/dog.jpg");
    t.applyMessage(
      meta({
        url: "http://localhost:4000/image/src/images/dog.jpg",
        ok: false,
        status: 422,
        statusText: "Unprocessable Entity",
        contentType: "text/plain",
        bytes: null,
        error: "invalid image request: bad_option",
      }),
    );
    expect(t.error).toBe("422 Unprocessable Entity: invalid image request: bad_option");
    expect(t.metadata).toBeNull();
  });
});

function fakeContainer(opts: { failRegister?: boolean } = {}) {
  const listeners = new Set<(e: MessageEvent) => void>();
  return {
    registered: [] as string[],
    removed: 0,
    ready: Promise.resolve({} as ServiceWorkerRegistration),
    addEventListener: (_t: string, cb: EventListener) => listeners.add(cb as never),
    removeEventListener: (_t: string, cb: EventListener) => {
      listeners.delete(cb as never);
    },
    register(url: string) {
      this.registered.push(url);
      return opts.failRegister
        ? Promise.reject(new Error("nope"))
        : Promise.resolve({} as ServiceWorkerRegistration);
    },
    emit(data: unknown) {
      for (const cb of listeners) cb({ data } as MessageEvent);
    },
    get listenerCount() {
      return listeners.size;
    },
  };
}

describe("registerPreviewWorker", () => {
  it("returns not-ready and never throws when the SW API is absent", async () => {
    const worker = await registerPreviewWorker(() => {}, undefined);
    expect(worker.ready).toBe(false);
  });

  it("registers the root-scoped worker and forwards parsed messages", async () => {
    const container = fakeContainer();
    const seen: string[] = [];
    const worker = await registerPreviewWorker((m) => seen.push(m.url), container as never);

    expect(worker.ready).toBe(true);
    expect(container.registered).toEqual([PREVIEW_WORKER_URL]);
    container.emit({ type: "preview-meta", url: "http://x/image/a" });
    container.emit({ type: "garbage" });
    expect(seen).toEqual(["http://x/image/a"]); // foreign message dropped by parser
  });

  it("cleans up the listener and reports not-ready when registration fails", async () => {
    const container = fakeContainer({ failRegister: true });
    const worker = await registerPreviewWorker(() => {}, container as never);
    expect(worker.ready).toBe(false);
    expect(container.listenerCount).toBe(0);
  });
});

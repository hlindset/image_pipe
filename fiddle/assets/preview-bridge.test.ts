import { describe, expect, it } from "vitest";

import {
  PREVIEW_WORKER_URL,
  PreviewMetadataTracker,
  registerPreviewWorker,
} from "./preview-bridge";

const meta = (over: Partial<Parameters<PreviewMetadataTracker["applyMessage"]>[0]> = {}) => ({
  type: "preview-meta" as const,
  url: "http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10",
  accept: "image/avif",
  ok: true,
  status: 200,
  statusText: "OK",
  contentType: "image/webp",
  bytes: 4321,
  error: null,
  ...over,
});

describe("PreviewMetadataTracker", () => {
  it("yields null metadata until dimensions arrive, then merges SW bytes/contentType", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10");

    // SW message arrives before onload: stashed, not yet renderable (needs dimensions).
    t.applyMessage(meta(), id);
    expect(t.metadata).toBeNull();
    expect(t.error).toBeNull();

    t.applyDimensions({ width: 10, height: 10 }, id);
    expect(t.metadata).toEqual({ width: 10, height: 10, bytes: 4321, contentType: "image/webp" });
  });

  it("merges when the SW message arrives AFTER onload", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/img/x");
    t.applyDimensions({ width: 5, height: 7 }, id);
    expect(t.metadata).toEqual({ width: 5, height: 7, bytes: null, contentType: null });

    t.applyMessage(
      meta({ url: "http://localhost:4000/img/x", bytes: 99, contentType: "image/avif" }),
      id,
    );
    expect(t.metadata).toEqual({ width: 5, height: 7, bytes: 99, contentType: "image/avif" });
  });

  it("drops stale messages from a superseded request id", () => {
    const t = new PreviewMetadataTracker();
    const stale = t.begin("http://localhost:4000/img/old");
    const fresh = t.begin("http://localhost:4000/img/new");

    t.applyMessage(meta({ url: "http://localhost:4000/img/old", bytes: 1 }), stale);
    t.applyDimensions({ width: 1, height: 1 }, fresh);
    expect(t.metadata).toEqual({ width: 1, height: 1, bytes: null, contentType: null });
  });

  it("drops a message whose url does not match the in-flight preview (query-sensitive)", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=10x10");
    t.applyDimensions({ width: 10, height: 10 }, id);
    t.applyMessage(
      meta({ url: "http://localhost:4000/twic/images/dog.jpg?twic=v1/cover=20x20" }),
      id,
    );
    expect(t.metadata?.bytes).toBeNull(); // different query → ignored
  });

  it("records an error from a non-ok SW message", () => {
    const t = new PreviewMetadataTracker();
    const id = t.begin("http://localhost:4000/img/x");
    t.applyMessage(
      meta({
        url: "http://localhost:4000/img/x",
        ok: false,
        status: 422,
        statusText: "Unprocessable Entity",
        contentType: "text/plain",
        bytes: null,
        error: "invalid image request: bad_option",
      }),
      id,
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
    container.emit({ type: "preview-meta", url: "http://x/img/a" });
    container.emit({ type: "garbage" });
    expect(seen).toEqual(["http://x/img/a"]); // foreign message dropped by parser
  });

  it("cleans up the listener and reports not-ready when registration fails", async () => {
    const container = fakeContainer({ failRegister: true });
    const worker = await registerPreviewWorker(() => {}, container as never);
    expect(worker.ready).toBe(false);
    expect(container.listenerCount).toBe(0);
  });
});

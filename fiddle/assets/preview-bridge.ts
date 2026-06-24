import { parsePreviewMeta, type PreviewMetaMessage } from "./preview-intercept";
import { type ProcessedImageMetadata } from "./processing-path";

type Dimensions = { width: number; height: number };

export class PreviewMetadataTracker {
  metadata: ProcessedImageMetadata | null = null;
  error: string | null = null;

  #requestId = 0;
  #url: string | null = null;
  #dimensions: Dimensions | null = null;
  #pending: { bytes: number | null; contentType: string | null } | null = null;

  // Start tracking a new preview. Returns the request id callers thread back into
  // applyDimensions/applyMessage so stale async arrivals are dropped.
  begin(url: string): number {
    this.#requestId += 1;
    this.#url = url;
    this.#dimensions = null;
    this.#pending = null;
    this.metadata = null;
    this.error = null;
    return this.#requestId;
  }

  applyDimensions(dimensions: Dimensions, requestId: number): void {
    if (requestId !== this.#requestId) return;
    this.#dimensions = dimensions;
    this.#recompute();
  }

  applyMessage(message: PreviewMetaMessage, requestId: number): void {
    if (requestId !== this.#requestId) return;
    if (message.url !== this.#url) return; // full-URL match (query-sensitive for TwicPics)

    if (!message.ok) {
      const suffix = message.error ? `: ${message.error}` : "";
      this.error = `${message.status} ${message.statusText}`.trim() + suffix;
      this.metadata = null;
      return;
    }

    this.#pending = { bytes: message.bytes, contentType: message.contentType };
    this.#recompute();
  }

  #recompute(): void {
    // error is terminal for a request: metadata and error are never both present,
    // regardless of whether dimensions arrive after a non-ok message.
    if (this.error !== null || this.#dimensions === null) {
      this.metadata = null;
      return;
    }
    this.metadata = {
      width: this.#dimensions.width,
      height: this.#dimensions.height,
      bytes: this.#pending?.bytes ?? null,
      contentType: this.#pending?.contentType ?? null,
    };
  }
}

// Served by Phoenix from root (:4000), NOT Vite (:5173) — a SW script must be
// same-origin with the page. Root path ⇒ default scope "/" ⇒ covers /img,
// /iiif-image, /twic with no Service-Worker-Allowed header needed.
export const PREVIEW_WORKER_URL = "/preview-sw.js";

export type PreviewWorker = { ready: boolean; unsubscribe: () => void };

export async function registerPreviewWorker(
  onMeta: (message: PreviewMetaMessage) => void,
  container: ServiceWorkerContainer | undefined = typeof navigator !== "undefined"
    ? navigator.serviceWorker
    : undefined,
): Promise<PreviewWorker> {
  if (container === undefined) return { ready: false, unsubscribe: () => {} };

  const listener = (event: MessageEvent) => {
    const message = parsePreviewMeta(event.data);
    if (message !== null) onMeta(message);
  };
  container.addEventListener("message", listener);

  try {
    await container.register(PREVIEW_WORKER_URL);
    await container.ready;
    return { ready: true, unsubscribe: () => container.removeEventListener("message", listener) };
  } catch {
    container.removeEventListener("message", listener);
    return { ready: false, unsubscribe: () => {} };
  }
}

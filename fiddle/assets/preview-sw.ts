/// <reference lib="webworker" />
import { extractDebugHeaders, isPreviewUrl, type PreviewMetaMessage } from "./preview-intercept";

const sw = self as unknown as ServiceWorkerGlobalScope;

sw.addEventListener("install", () => {
  void sw.skipWaiting();
});

sw.addEventListener("activate", (event) => {
  event.waitUntil(sw.clients.claim());
});

sw.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET" || !isPreviewUrl(request.url)) return;
  event.respondWith(handlePreview(event, request));
});

async function handlePreview(event: FetchEvent, request: Request): Promise<Response> {
  // Forward the request UNCHANGED so the browser's real Accept reaches the server
  // and a decodable format is negotiated. Read metadata off a clone so the original
  // stream still reaches the <img> untouched.
  const accept = request.headers.get("accept");
  const response = await fetch(request);
  event.waitUntil(reportMetadata(event.clientId, request.url, accept, response.clone()));
  return response;
}

async function reportMetadata(
  clientId: string,
  url: string,
  accept: string | null,
  response: Response,
): Promise<void> {
  try {
    const debugHeaders = extractDebugHeaders(response.headers);
    const body = await response.arrayBuffer(); // demo payloads are small; buffering to count bytes is fine
    const message: PreviewMetaMessage = {
      type: "preview-meta",
      url,
      accept,
      ok: response.ok,
      status: response.status,
      statusText: response.statusText,
      contentType: response.headers.get("content-type"),
      bytes: body.byteLength,
      error: response.ok ? null : errorSnippet(response, body),
      debugHeaders,
    };
    await postToClient(clientId, message);
  } catch {
    // Metadata is best-effort; never disrupt the image render.
  }
}

async function postToClient(clientId: string, message: PreviewMetaMessage): Promise<void> {
  const client = clientId ? await sw.clients.get(clientId) : undefined;
  client?.postMessage(message);
}

function errorSnippet(response: Response, body: ArrayBuffer): string | null {
  const contentType = response.headers.get("content-type") ?? "";
  if (!contentType.startsWith("text/")) return null;
  try {
    return new TextDecoder().decode(body).trim().slice(0, 180) || null;
  } catch {
    return null;
  }
}

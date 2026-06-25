// The fiddle's three processing endpoints (router forwards: /img, /iiif-image, /twic).
// All run the same Plan.Output negotiation, so one interceptor covers them. Match on
// pathname so the TwicPics `?twic=…` query is ignored. `/twicpics/` is the display-only
// copy link (twicBrowserPath) and is intentionally excluded.
export const PREVIEW_PREFIXES = ["/img/", "/iiif-image/", "/twic/"] as const;

export function isPreviewUrl(url: string): boolean {
  let pathname: string;
  try {
    pathname = new URL(url).pathname;
  } catch {
    return false;
  }
  return PREVIEW_PREFIXES.some((prefix) => pathname.startsWith(prefix));
}

// Collect the opt-in debug headers (X-ImagePipe-* + standard Server-Timing) off a
// response. Returns null when none are present so the message stays compact.
// `Headers` iteration yields lowercased names per the Fetch spec.
export function extractDebugHeaders(headers: Headers): Record<string, string> | null {
  const out: Record<string, string> = {};
  for (const [name, value] of headers) {
    if (name.startsWith("x-imagepipe-") || name === "server-timing") out[name] = value;
  }
  return Object.keys(out).length > 0 ? out : null;
}

// The metadata the worker reports back to the page for the request the browser made.
export type PreviewMetaMessage = {
  type: "preview-meta";
  url: string;
  accept: string | null;
  ok: boolean;
  status: number;
  statusText: string;
  contentType: string | null;
  bytes: number | null;
  error: string | null;
  debugHeaders: Record<string, string> | null;
};

// Boundary parser: postMessage data is untrusted (any page script can post). Validate
// shape, coerce optionals to safe defaults, reject anything that is not our message.
export function parsePreviewMeta(data: unknown): PreviewMetaMessage | null {
  if (typeof data !== "object" || data === null) return null;
  const m = data as Record<string, unknown>;
  if (m.type !== "preview-meta" || typeof m.url !== "string") return null;
  return {
    type: "preview-meta",
    url: m.url,
    accept: typeof m.accept === "string" ? m.accept : null,
    ok: m.ok === true,
    status: typeof m.status === "number" && Number.isFinite(m.status) ? m.status : 0,
    statusText: typeof m.statusText === "string" ? m.statusText : "",
    contentType: typeof m.contentType === "string" ? m.contentType : null,
    bytes: typeof m.bytes === "number" && Number.isFinite(m.bytes) ? m.bytes : null,
    error: typeof m.error === "string" ? m.error : null,
    debugHeaders: parseDebugHeaderRecord(m.debugHeaders),
  };
}

// Untrusted postMessage record: keep only string→string entries; null if empty.
function parseDebugHeaderRecord(value: unknown): Record<string, string> | null {
  if (typeof value !== "object" || value === null) return null;
  const out: Record<string, string> = {};
  for (const [name, raw] of Object.entries(value as Record<string, unknown>)) {
    if (typeof raw === "string") out[name] = raw;
  }
  return Object.keys(out).length > 0 ? out : null;
}

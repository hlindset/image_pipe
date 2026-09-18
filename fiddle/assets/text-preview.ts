import { extractDebugHeaders } from "./preview-intercept";

export type TextPreview = {
  text: string;
  bytes: number;
  contentType: string;
  debugHeaders: Record<string, string> | null;
};

export function isTextPreview(path: string): boolean {
  const prefix = ["/native-image/", "/native-signed/"].find((candidate) =>
    path.startsWith(candidate),
  );
  if (prefix === undefined) return false;
  const segments = path.slice(prefix.length).split("/");
  const sourceIndex = segments.findIndex((segment) => ["src", "src64", "enc"].includes(segment));
  return segments
    .slice(0, sourceIndex)
    .some((segment) => segment === "output=info" || segment === "output=blurhash");
}

export async function readTextPreview(response: Response): Promise<TextPreview> {
  const body = await response.text();
  if (!response.ok) throw new Error(`${response.status}: ${body || response.statusText}`);
  const contentType = response.headers.get("content-type")?.split(";")[0] ?? "text/plain";
  return {
    text: contentType === "application/json" ? JSON.stringify(JSON.parse(body), null, 2) : body,
    bytes: new TextEncoder().encode(body).byteLength,
    contentType,
    debugHeaders: extractDebugHeaders(response.headers),
  };
}

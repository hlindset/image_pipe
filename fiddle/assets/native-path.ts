import {
  parseSourceIdentifier,
  sampleImages,
  sourceIdentifierForRequest,
  type SourceImage,
  type SourceType,
} from "./source";

export type Protection = "unsigned" | "signed" | "signed-concealed";
export type NativeState = {
  source: SourceImage;
  sourceType: SourceType;
  options: string;
  protection: Protection;
};

export const defaultNativeState: NativeState = {
  source: "images/dog.jpg",
  sourceType: "local",
  options: "w=800",
  protection: "unsigned",
};

export function resetNativeSettings(currentState: NativeState): NativeState {
  return {
    ...defaultNativeState,
    source: currentState.source,
    sourceType: currentState.sourceType,
  };
}

export function nativeTail(state: NativeState): string {
  const identifier =
    state.sourceType === "local"
      ? state.source
      : sourceIdentifierForRequest(state.source, state.sourceType);
  const source = identifier.split("/").map(encodeURIComponent).join("/");
  return `${state.options ? `${state.options}/` : ""}src/${source}`;
}

export function nativeFetchPath(state: NativeState): string {
  return `/native-image/${nativeTail(state)}`;
}

export async function resolveNativeFetchPath(
  state: NativeState,
  fetcher: typeof fetch = fetch,
): Promise<string> {
  if (state.protection === "unsigned") return nativeFetchPath(state);

  const response = await fetcher("/api/native-path", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ tail: nativeTail(state), protection: state.protection }),
  });
  if (!response.ok) throw new Error("Unable to protect preview request");

  const result = (await response.json()) as { path?: unknown };
  if (typeof result.path !== "string") throw new Error("Invalid protected preview response");
  return result.path;
}

export class NativePathResolution {
  private requestId = 0;

  begin(state: NativeState): { requestId: number; path: string | null } {
    const requestId = ++this.requestId;
    const path = state.protection === "unsigned" ? nativeFetchPath(state) : null;
    return { requestId, path };
  }

  accept(requestId: number, path: string): string | null {
    return requestId === this.requestId ? path : null;
  }

  reject(requestId: number): boolean {
    return requestId === this.requestId;
  }
}

export function nativeBrowserPath(state: NativeState): string {
  const protection = state.protection === "unsigned" ? "" : `${state.protection}/`;
  return `/native/${protection}${nativeTail(state)}`;
}

export function parseNativeTail(tail: string): NativeState | null {
  const segments = tail.split("/");
  const sourceIndex = segments.indexOf("src");
  if (sourceIndex < 0) return null;
  let identifier: string;
  try {
    identifier = decodeURIComponent(segments.slice(sourceIndex + 1).join("/"));
  } catch {
    return null;
  }
  const image = sampleImages.find((image) => image.path === identifier);
  const source = image
    ? { source: image.path, sourceType: "local" as const }
    : parseSourceIdentifier(identifier);
  if (!source) return null;
  if (!image && source.sourceType === "local") return null;
  return {
    ...source,
    options: segments.slice(0, sourceIndex).join("/"),
    protection: "unsigned",
  };
}

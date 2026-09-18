import {
  parseSourceIdentifier,
  sampleImages,
  sourceIdentifierForRequest,
  type SourceImage,
  type SourceType,
} from "./processing-path";

export type NativeState = { source: SourceImage; sourceType: SourceType; options: string };

export const defaultNativeState: NativeState = {
  source: "images/dog.jpg",
  sourceType: "local",
  options: "w=800",
};

export function resetNativeSettings(currentState: NativeState): NativeState {
  return {
    ...defaultNativeState,
    source: currentState.source,
    sourceType: currentState.sourceType,
  };
}

function nativeTail(state: NativeState): string {
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

export function nativeBrowserPath(state: NativeState): string {
  return `/native/${nativeTail(state)}`;
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
  return { ...source, options: segments.slice(0, sourceIndex).join("/") };
}

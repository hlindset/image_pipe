import { sampleImages, type SourceImage } from "./processing-path";

export type NativeState = { source: SourceImage; options: string };

export const defaultNativeState: NativeState = {
  source: "images/dog.jpg",
  options: "w=800",
};

function nativeTail(state: NativeState): string {
  return `${state.options ? `${state.options}/` : ""}src/${state.source}`;
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
  const source = segments.slice(sourceIndex + 1).join("/");
  const image = sampleImages.find((image) => image.path === source);
  if (!image) return null;
  return { source: image.path, options: segments.slice(0, sourceIndex).join("/") };
}

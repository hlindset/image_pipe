import { sampleImages } from "virtual:sample-images";

export type SourceImage = (typeof sampleImages)[number]["path"];
export type SourceType = "local" | "s3" | "http";

const localSourceScheme = "local:///";
const s3SourceBucketPrefix = "s3://sources/";
const defaultHttpSourcePrefix = "http://localhost:4000/";
const loopbackHttpSourcePattern = /^https?:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?\//;

export { sampleImages };

export function sourceIdentifierForRequest(source: SourceImage, sourceType: SourceType): string {
  switch (sourceType) {
    case "local":
      return `${localSourceScheme}${source}`;
    case "s3":
      return `${s3SourceBucketPrefix}${source.slice(source.lastIndexOf("/") + 1)}`;
    case "http":
      return `${httpSourcePrefix()}${source}`;
  }
}

export function parseSourceIdentifier(
  identifier: string,
): { source: SourceImage; sourceType: SourceType } | null {
  const candidate = sourceTypeAndPath(identifier);

  if (candidate === null) return null;

  const known = sampleImages.some((image) => image.path === candidate.source);
  return known
    ? { source: candidate.source as SourceImage, sourceType: candidate.sourceType }
    : null;
}

function sourceTypeAndPath(identifier: string): { source: string; sourceType: SourceType } | null {
  if (identifier.startsWith(localSourceScheme)) {
    return { source: identifier.slice(localSourceScheme.length), sourceType: "local" };
  }

  const httpPrefix = identifier.match(loopbackHttpSourcePattern)?.[0];
  if (httpPrefix !== undefined) {
    return { source: identifier.slice(httpPrefix.length), sourceType: "http" };
  }

  if (identifier.startsWith(s3SourceBucketPrefix)) {
    return { source: `images/${identifier.slice(s3SourceBucketPrefix.length)}`, sourceType: "s3" };
  }

  return null;
}

function httpSourcePrefix(): string {
  const location = globalThis.location;

  if (
    location !== undefined &&
    (location.hostname === "localhost" || location.hostname === "127.0.0.1") &&
    (location.protocol === "http:" || location.protocol === "https:")
  ) {
    return `${location.origin}/`;
  }

  return defaultHttpSourcePrefix;
}

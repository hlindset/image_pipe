export type ProcessedImageMetadata = {
  width: number;
  height: number;
  bytes: number | null;
  contentType: string | null;
  debugHeaders: Record<string, string> | null;
};

export function debounce<Arguments extends unknown[]>(
  callback: (...args: Arguments) => void,
  delayMs: number,
): (...args: Arguments) => void {
  let timeoutId: ReturnType<typeof setTimeout> | null = null;

  return (...args: Arguments) => {
    if (timeoutId !== null) clearTimeout(timeoutId);

    timeoutId = setTimeout(() => {
      callback(...args);
    }, delayMs);
  };
}

export function debouncePreviewPath(
  callback: (path: string) => void,
  delayMs: number,
): (path: string | null) => void {
  return debounce((path: string | null) => {
    if (path !== null) callback(path);
  }, delayMs);
}

export function processedSizeLabel(metadata: ProcessedImageMetadata | null): string {
  if (metadata === null) return "Loading";

  const dimensions = `${metadata.width} × ${metadata.height}`;
  if (metadata.bytes === null) return dimensions;

  const kilobytes = Math.max(1, Math.round(metadata.bytes / 1024));
  return `${dimensions} (${kilobytes} kB)`;
}

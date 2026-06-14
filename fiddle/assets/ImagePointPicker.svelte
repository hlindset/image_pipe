<script lang="ts">
  // Shared click/drag/keyboard picker over an image: maps pointer position to a
  // normalized 0..1 point and reports it via `onPick`. Consumers decide what the
  // point means (imgproxy: a focal point stored as 0..1; TwicPics: a pixel crop
  // origin derived from the loaded image's natural dimensions). Optional `overlay`
  // snippet draws extra marks (e.g. a crop region) inside the image surface.
  import type { Snippet } from "svelte";
  import { focalPointFromBounds } from "./processing-path";

  type Props = {
    src: string;
    markerX: number; // 0..1
    markerY: number; // 0..1
    onPick: (nx: number, ny: number) => void;
    naturalWidth?: number; // [$bindable] natural px width once the image loads (0 until then)
    naturalHeight?: number; // [$bindable]
    ariaLabel?: string;
    overlay?: Snippet;
    keyStep?: number;
    keyStepShift?: number;
  };

  let {
    src,
    markerX,
    markerY,
    onPick,
    naturalWidth = $bindable(0),
    naturalHeight = $bindable(0),
    ariaLabel = "Set point",
    overlay,
    keyStep = 0.01,
    keyStepShift = 0.1,
  }: Props = $props();

  let surface: HTMLSpanElement | null = $state(null);

  function onImageLoad(event: Event): void {
    const img = event.currentTarget;
    if (img instanceof HTMLImageElement) {
      naturalWidth = img.naturalWidth;
      naturalHeight = img.naturalHeight;
    }
  }

  function pickFromEvent(event: MouseEvent | PointerEvent): void {
    // Ignore the synthetic click a keyboard activation fires (detail === 0).
    if (event instanceof MouseEvent && event.type === "click" && event.detail === 0) return;
    if (surface === null) return;

    const point = focalPointFromBounds(
      event.clientX,
      event.clientY,
      surface.getBoundingClientRect(),
    );
    onPick(point.x, point.y);
  }

  function startDrag(event: PointerEvent): void {
    const target = event.currentTarget;
    if (target instanceof HTMLElement) target.setPointerCapture(event.pointerId);
    pickFromEvent(event);
  }

  function drag(event: PointerEvent): void {
    if (event.buttons !== 1) return;
    pickFromEvent(event);
  }

  function clamp01(value: number): number {
    return Math.min(1, Math.max(0, Math.round(value * 100) / 100));
  }

  function moveKey(event: KeyboardEvent): void {
    const step = event.shiftKey ? keyStepShift : keyStep;

    if (event.key === "ArrowLeft") {
      event.preventDefault();
      onPick(clamp01(markerX - step), markerY);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      onPick(clamp01(markerX + step), markerY);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      onPick(markerX, clamp01(markerY - step));
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      onPick(markerX, clamp01(markerY + step));
    } else if (event.key === "Home") {
      event.preventDefault();
      onPick(0.5, 0.5);
    }
  }
</script>

<button
  class="point-picker"
  type="button"
  aria-label={ariaLabel}
  onclick={pickFromEvent}
  onkeydown={moveKey}
  onpointerdown={startDrag}
  onpointermove={drag}
>
  <span class="point-picker-surface" bind:this={surface}>
    <img {src} alt="" draggable="false" onload={onImageLoad} />
    {@render overlay?.()}
    <span class="point-picker-marker" style={`left: ${markerX * 100}%; top: ${markerY * 100}%;`}
    ></span>
  </span>
</button>

<style>
  .point-picker {
    width: 100%;
    height: 148px;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-control) 0 50%)
      50% / 16px 16px;
    cursor: crosshair;
    padding: 8px;
    touch-action: none;
  }

  .point-picker:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .point-picker-surface {
    position: relative;
    display: inline-flex;
    max-width: 100%;
    max-height: 100%;
    box-shadow: var(--image-shadow);
  }

  .point-picker-surface img {
    display: block;
    width: auto;
    height: auto;
    max-width: 100%;
    max-height: 130px;
    pointer-events: none;
    user-select: none;
  }

  .point-picker-marker {
    position: absolute;
    width: 18px;
    height: 18px;
    border: 2px solid var(--accent);
    border-radius: 999px;
    box-shadow:
      0 0 0 1px var(--surface-sidebar),
      0 2px 10px rgb(0 0 0 / 0.38);
    pointer-events: none;
    transform: translate(-50%, -50%);
  }

  .point-picker-marker::before,
  .point-picker-marker::after {
    position: absolute;
    inset: 50% auto auto 50%;
    display: block;
    background: var(--accent);
    content: "";
    transform: translate(-50%, -50%);
  }

  .point-picker-marker::before {
    width: 24px;
    height: 2px;
  }

  .point-picker-marker::after {
    width: 2px;
    height: 24px;
  }
</style>

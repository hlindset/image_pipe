<script lang="ts">
  // Click/drag a minimap of the *running* image (the result of the chain up to,
  // but not including, this crop) to set the crop origin in pixels. Because crop
  // `@XxY` is in pixels of the running image, the preview src is the partial-chain
  // result, not the source — so the picker is correct at any pipeline position.
  type Props = {
    previewSrc: string;
    width: number; // crop width (px) — for the region overlay
    height: number; // crop height (px)
    x: number; // origin X (px) [$bindable]
    y: number; // origin Y (px) [$bindable]
  };

  let { previewSrc, width, height, x = $bindable(), y = $bindable() }: Props = $props();

  let surface: HTMLSpanElement | null = $state(null);
  // Natural pixel dimensions of the running image, read once it loads. 0 until then.
  let runningWidth = $state(0);
  let runningHeight = $state(0);

  const ready = $derived(runningWidth > 0 && runningHeight > 0);

  function clampX(value: number): number {
    return runningWidth > 0 ? Math.min(Math.max(Math.round(value), 1), runningWidth) : value;
  }

  function clampY(value: number): number {
    return runningHeight > 0 ? Math.min(Math.max(Math.round(value), 1), runningHeight) : value;
  }

  function onImageLoad(event: Event): void {
    const img = event.currentTarget;
    if (img instanceof HTMLImageElement) {
      runningWidth = img.naturalWidth;
      runningHeight = img.naturalHeight;
      // Re-clamp the existing origin into the (possibly changed) running frame.
      x = clampX(x);
      y = clampY(y);
    }
  }

  function setFromEvent(event: MouseEvent | PointerEvent): void {
    // Ignore the synthetic click a keyboard activation fires (detail === 0).
    if (event instanceof MouseEvent && event.type === "click" && event.detail === 0) return;
    if (surface === null || !ready) return;

    const bounds = surface.getBoundingClientRect();
    if (bounds.width <= 0 || bounds.height <= 0) return;

    const fractionX = Math.min(Math.max((event.clientX - bounds.left) / bounds.width, 0), 1);
    const fractionY = Math.min(Math.max((event.clientY - bounds.top) / bounds.height, 0), 1);
    x = clampX(fractionX * runningWidth);
    y = clampY(fractionY * runningHeight);
  }

  function startDrag(event: PointerEvent): void {
    const target = event.currentTarget;
    if (target instanceof HTMLElement) target.setPointerCapture(event.pointerId);
    setFromEvent(event);
  }

  function drag(event: PointerEvent): void {
    if (event.buttons !== 1) return;
    setFromEvent(event);
  }

  function moveKey(event: KeyboardEvent): void {
    if (!ready) return;
    const stepPx = event.shiftKey ? 10 : 1;

    if (event.key === "ArrowLeft") {
      event.preventDefault();
      x = clampX(x - stepPx);
    } else if (event.key === "ArrowRight") {
      event.preventDefault();
      x = clampX(x + stepPx);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      y = clampY(y - stepPx);
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      y = clampY(y + stepPx);
    }
  }

  const leftPct = $derived(ready ? (x / runningWidth) * 100 : 0);
  const topPct = $derived(ready ? (y / runningHeight) * 100 : 0);
  const widthPct = $derived(ready ? (width / runningWidth) * 100 : 0);
  const heightPct = $derived(ready ? (height / runningHeight) * 100 : 0);
</script>

<div class="origin-picker-field">
  <span>Origin (click to set)</span>
  <button
    class="origin-picker"
    type="button"
    aria-label={`Set crop origin, currently ${x}, ${y} pixels`}
    onclick={setFromEvent}
    onkeydown={moveKey}
    onpointerdown={startDrag}
    onpointermove={drag}
  >
    <span class="origin-image-surface" bind:this={surface}>
      <img src={previewSrc} alt="" draggable="false" onload={onImageLoad} />
      {#if ready}
        <span
          class="origin-rect"
          style={`left:${leftPct}%; top:${topPct}%; width:${widthPct}%; height:${heightPct}%;`}
        ></span>
        <span class="origin-marker" style={`left:${leftPct}%; top:${topPct}%;`}></span>
      {/if}
    </span>
  </button>
</div>

<style>
  .origin-picker-field {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .origin-picker {
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
    padding: 0;
    cursor: crosshair;
    touch-action: none;
  }

  .origin-picker:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .origin-image-surface {
    position: relative;
    display: inline-flex;
    max-width: 100%;
    max-height: 100%;
  }

  .origin-image-surface img {
    display: block;
    max-width: 100%;
    max-height: 146px;
    width: auto;
    height: auto;
    user-select: none;
  }

  /* The crop region anchored at the origin (top-left). Clipped by the picker's
     overflow when it extends past the running frame. */
  .origin-rect {
    position: absolute;
    border: 1px solid var(--accent);
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    pointer-events: none;
  }

  .origin-marker {
    position: absolute;
    width: 14px;
    height: 14px;
    border: 2px solid var(--accent);
    border-radius: 999px;
    box-shadow:
      0 0 0 1px var(--surface-sidebar),
      0 2px 8px rgb(0 0 0 / 0.38);
    pointer-events: none;
    transform: translate(-50%, -50%);
  }
</style>

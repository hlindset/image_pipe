<script lang="ts">
  // Crop origin picker: a thin wrapper over ImagePointPicker that converts the
  // normalized point into running-image pixels. The preview is the partial-chain
  // result (the chain up to, but not including, this crop), so the pixel space
  // matches what `crop=WxH@XxY` addresses at this point in the pipeline.
  import ImagePointPicker from "./ImagePointPicker.svelte";

  type Props = {
    previewSrc: string;
    width: number; // crop width (px) — for the region overlay
    height: number; // crop height (px)
    x: number; // origin X (px) [$bindable]
    y: number; // origin Y (px) [$bindable]
  };

  let { previewSrc, width, height, x = $bindable(), y = $bindable() }: Props = $props();

  let runningWidth = $state(0);
  let runningHeight = $state(0);
  const ready = $derived(runningWidth > 0 && runningHeight > 0);

  function clampX(value: number): number {
    return runningWidth > 0 ? Math.min(Math.max(Math.round(value), 1), runningWidth) : value;
  }

  function clampY(value: number): number {
    return runningHeight > 0 ? Math.min(Math.max(Math.round(value), 1), runningHeight) : value;
  }

  // Re-clamp the origin into the running frame whenever a new preview loads (a
  // changed earlier chain step can shrink the running image).
  $effect(() => {
    if (runningWidth > 0) {
      const cx = clampX(x);
      if (cx !== x) x = cx;
    }
    if (runningHeight > 0) {
      const cy = clampY(y);
      if (cy !== y) y = cy;
    }
  });

  function pick(nx: number, ny: number): void {
    if (!ready) return;
    x = clampX(nx * runningWidth);
    y = clampY(ny * runningHeight);
  }

  const markerX = $derived(ready ? x / runningWidth : 0);
  const markerY = $derived(ready ? y / runningHeight : 0);
</script>

<div class="origin-picker-field">
  <span>Origin (click to set)</span>
  <ImagePointPicker
    src={previewSrc}
    {markerX}
    {markerY}
    bind:naturalWidth={runningWidth}
    bind:naturalHeight={runningHeight}
    ariaLabel={`Set crop origin, currently ${x}, ${y} pixels`}
    onPick={pick}
  >
    {#snippet overlay()}
      {#if ready}
        <span
          class="origin-rect"
          style={`left:${markerX * 100}%; top:${markerY * 100}%; width:${(width / runningWidth) * 100}%; height:${(height / runningHeight) * 100}%;`}
        ></span>
      {/if}
    {/snippet}
  </ImagePointPicker>
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

  /* The crop region anchored at the origin (top-left). Clipped by the picker's
     overflow when it extends past the running frame. */
  .origin-rect {
    position: absolute;
    border: 1px solid var(--accent);
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    pointer-events: none;
  }
</style>

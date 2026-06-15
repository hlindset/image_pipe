<script lang="ts">
  // Crop origin picker: a thin wrapper over ImagePointPicker that converts the
  // normalized point into running-image pixels. The preview is the partial-chain
  // result (the chain up to, but not including, this crop), so the pixel space
  // matches what `crop=WxH@XxY` addresses at this point in the pipeline.
  import ImagePointPicker from "./ImagePointPicker.svelte";
  import RangeNumber from "./RangeNumber.svelte";

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

  // Mirror the backend's region clamping (crop.ex): the crop size is capped to the
  // running image, and the origin (top-left) is shifted into [0, running - size] so
  // the rectangle always fits. So the effective max origin shrinks as the crop grows,
  // and the preview box below is exactly the resulting crop — never drawn outside.
  const effWidth = $derived(ready ? Math.min(width, runningWidth) : width);
  const effHeight = $derived(ready ? Math.min(height, runningHeight) : height);
  const maxX = $derived(ready ? Math.max(1, runningWidth - effWidth) : 8000);
  const maxY = $derived(ready ? Math.max(1, runningHeight - effHeight) : 8000);

  function clampX(value: number): number {
    return ready ? Math.min(Math.max(Math.round(value), 1), maxX) : value;
  }

  function clampY(value: number): number {
    return ready ? Math.min(Math.max(Math.round(value), 1), maxY) : value;
  }

  // Re-clamp the origin into the effective range whenever the running image or the
  // crop size changes (both move where a fully-in-frame origin can sit).
  $effect(() => {
    if (ready) {
      const cx = clampX(x);
      if (cx !== x) x = cx;
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
          style={`left:${markerX * 100}%; top:${markerY * 100}%; width:${(effWidth / runningWidth) * 100}%; height:${(effHeight / runningHeight) * 100}%;`}
        ></span>
      {/if}
    {/snippet}
  </ImagePointPicker>

  <RangeNumber label="X" bind:value={x} min={1} max={maxX} step={1} suffix="px" />
  <RangeNumber label="Y" bind:value={y} min={1} max={maxY} step={1} suffix="px" />
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

  /* The resulting crop region (origin = top-left), already clamped to fit the frame. */
  .origin-rect {
    position: absolute;
    border: 1px solid var(--accent);
    background: color-mix(in srgb, var(--accent) 18%, transparent);
    pointer-events: none;
  }
</style>

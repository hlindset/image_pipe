<script lang="ts">
  // Crop origin picker: a thin wrapper over ImagePointPicker that converts the
  // normalized point into a running-image origin, expressed in the origin's chosen
  // unit (px / % / scale). The preview is the partial-chain result (the chain up to,
  // but not including, this crop), so the pixel space matches what `crop=WxH@XxY`
  // addresses at this point in the pipeline. Origin coordinates are zero-based.
  import ImagePointPicker from "./ImagePointPicker.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import type { TwicLen, TwicLenUnit } from "./twicpics-path";

  type Props = {
    previewSrc: string;
    width: TwicLen; // crop width — for the region overlay
    height: TwicLen; // crop height
    x: TwicLen; // origin X [$bindable]
    y: TwicLen; // origin Y [$bindable]
  };

  let { previewSrc, width, height, x = $bindable(), y = $bindable() }: Props = $props();

  let runningWidth = $state(0);
  let runningHeight = $state(0);
  const ready = $derived(runningWidth > 0 && runningHeight > 0);

  // Resolve a length to running-image pixels along an axis: px is literal, percent
  // is of the axis, scale is a fraction of the axis.
  function toPx(len: TwicLen, axisPx: number): number {
    switch (len.unit) {
      case "p":
        return (len.value / 100) * axisPx;
      case "s":
        return len.value * axisPx;
      default:
        return len.value;
    }
  }

  // Express a running-image pixel position back in the origin's chosen unit.
  function fromPx(px: number, unit: TwicLenUnit, axisPx: number): number {
    switch (unit) {
      case "p":
        return axisPx > 0 ? (px / axisPx) * 100 : 0;
      case "s":
        return axisPx > 0 ? px / axisPx : 0;
      default:
        return px;
    }
  }

  function roundForUnit(value: number, unit: TwicLenUnit): number {
    const factor = unit === "s" ? 100 : unit === "p" ? 10 : 1;
    return Math.round(value * factor) / factor;
  }

  // Mirror the backend's region clamping (crop.ex): the crop size is capped to the
  // running image, and the origin (top-left) is shifted into [0, running - size] so
  // the rectangle always fits.
  const effWidth = $derived(ready ? Math.min(toPx(width, runningWidth), runningWidth) : 0);
  const effHeight = $derived(ready ? Math.min(toPx(height, runningHeight), runningHeight) : 0);
  const maxXpx = $derived(ready ? Math.max(0, runningWidth - effWidth) : 0);
  const maxYpx = $derived(ready ? Math.max(0, runningHeight - effHeight) : 0);

  function clampPx(value: number, maxPx: number): number {
    return Math.min(Math.max(value, 0), maxPx);
  }

  // Current origin position in running pixels.
  const xPx = $derived(ready ? clampPx(toPx(x, runningWidth), maxXpx) : 0);
  const yPx = $derived(ready ? clampPx(toPx(y, runningHeight), maxYpx) : 0);

  function applyX(px: number): void {
    x = {
      unit: x.unit,
      value: roundForUnit(fromPx(clampPx(px, maxXpx), x.unit, runningWidth), x.unit),
    };
  }

  function applyY(px: number): void {
    y = {
      unit: y.unit,
      value: roundForUnit(fromPx(clampPx(px, maxYpx), y.unit, runningHeight), y.unit),
    };
  }

  // Re-clamp the origin into the effective range whenever the running image or the
  // crop size changes (both move where a fully-in-frame origin can sit).
  $effect(() => {
    if (ready) {
      const cx = clampPx(toPx(x, runningWidth), maxXpx);
      if (cx !== toPx(x, runningWidth)) applyX(cx);
      const cy = clampPx(toPx(y, runningHeight), maxYpx);
      if (cy !== toPx(y, runningHeight)) applyY(cy);
    }
  });

  function pick(nx: number, ny: number): void {
    if (!ready) return;
    applyX(nx * runningWidth);
    applyY(ny * runningHeight);
  }

  const markerX = $derived(ready ? xPx / runningWidth : 0);
  const markerY = $derived(ready ? yPx / runningHeight : 0);

  // Per-unit range + suffix for the numeric X/Y sliders (origin is zero-based).
  function originRange(unit: TwicLenUnit): { max: number; step: number; suffix: string } {
    switch (unit) {
      case "p":
        return { max: 100, step: 1, suffix: "%" };
      case "s":
        return { max: 1, step: 0.01, suffix: "×" };
      default:
        return { max: ready ? runningWidth : 8000, step: 1, suffix: "px" };
    }
  }

  const xRange = $derived(originRange(x.unit));
  const yRange = $derived(originRange(y.unit));
</script>

<div class="origin-picker-field">
  <ImagePointPicker
    src={previewSrc}
    {markerX}
    {markerY}
    bind:naturalWidth={runningWidth}
    bind:naturalHeight={runningHeight}
    ariaLabel={`Set crop origin, currently ${x.value}${xRange.suffix}, ${y.value}${yRange.suffix}`}
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

  <RangeNumber
    label="X"
    value={x.value}
    min={0}
    max={xRange.max}
    step={xRange.step}
    inputStep={x.unit === "s" ? "any" : xRange.step}
    suffix={xRange.suffix}
    onValueChange={(v) => (x = { unit: x.unit, value: roundForUnit(v, x.unit) })}
  />
  <RangeNumber
    label="Y"
    value={y.value}
    min={0}
    max={yRange.max}
    step={yRange.step}
    inputStep={y.unit === "s" ? "any" : yRange.step}
    suffix={yRange.suffix}
    onValueChange={(v) => (y = { unit: y.unit, value: roundForUnit(v, y.unit) })}
  />
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

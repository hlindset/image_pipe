<script lang="ts">
  // All controls for a `crop` step. Loads the running-image preview (the chain up
  // to, but not including, this crop) once to learn its pixel dimensions, so the
  // px-unit W/H and origin sliders are bounded by what's actually addressable rather
  // than a flat cap. The minimap origin picker reuses the same preview.
  //
  // Crop W/H and the origin coordinates carry a unit suffix (px / % / scale), the
  // same px/p/s picker the resize control uses. Crop size is strictly > 0; the
  // origin is zero-based (so `@0x0` is the top-left).
  import { Slider, Switch } from "bits-ui";
  import TwicCropOriginPicker from "./TwicCropOriginPicker.svelte";
  import type { TwicLen, TwicLenUnit } from "./twicpics-path";

  type Props = {
    previewSrc: string;
    width: TwicLen; // crop width [$bindable]
    height: TwicLen; // crop height [$bindable]
    origin: { x: TwicLen; y: TwicLen } | null; // [$bindable]
  };

  let {
    previewSrc,
    width = $bindable(),
    height = $bindable(),
    origin = $bindable(),
  }: Props = $props();

  let runningWidth = $state(0);
  let runningHeight = $state(0);

  function onDimsLoad(event: Event): void {
    const img = event.currentTarget;
    if (img instanceof HTMLImageElement) {
      runningWidth = img.naturalWidth;
      runningHeight = img.naturalHeight;
    }
  }

  function toggleOrigin(on: boolean): void {
    origin = on ? { x: { unit: "px", value: 0 }, y: { unit: "px", value: 0 } } : null;
  }

  // Per-unit slider range + suffix. Pixel size tracks the running axis (cap at the
  // addressable extent); percent is 1..100 of that axis; scale is a fraction of it.
  // `allowZero` lowers the floor for origin coordinates (so the top-left is `0`).
  function unitRange(
    unit: TwicLenUnit,
    axisPx: number,
    allowZero: boolean,
  ): { min: number; max: number; step: number; suffix: string } {
    const floor = allowZero ? 0 : 1;
    switch (unit) {
      case "p":
        return { min: allowZero ? 0 : 1, max: 100, step: 1, suffix: "%" };
      case "s":
        return { min: allowZero ? 0 : 0.1, max: 1, step: 0.1, suffix: "×" };
      default:
        return { min: floor, max: axisPx > 0 ? axisPx : 8000, step: 1, suffix: "px" };
    }
  }

  function clampToRange(
    value: number,
    unit: TwicLenUnit,
    axisPx: number,
    allowZero: boolean,
  ): number {
    const { min, max, step } = unitRange(unit, axisPx, allowZero);
    const clamped = Math.min(Math.max(value, min), max);
    const factor = step < 1 ? 10 : 1;
    return Math.round(clamped * factor) / factor;
  }

  function setLen(len: TwicLen, value: number, axisPx: number, allowZero: boolean): TwicLen {
    if (Number.isNaN(value)) return len;
    return { unit: len.unit, value: clampToRange(value, len.unit, axisPx, allowZero) };
  }

  // Switch a length's unit, carrying a sensible value into the new unit's range.
  function changeUnit(
    len: TwicLen,
    unit: TwicLenUnit,
    axisPx: number,
    allowZero: boolean,
  ): TwicLen {
    const fallback =
      unit === "s"
        ? allowZero
          ? 0
          : 1
        : unit === "p"
          ? allowZero
            ? 0
            : 50
          : axisPx > 0
            ? Math.round(axisPx / 2)
            : 300;
    const carried = unit === len.unit ? len.value : fallback;
    return { unit, value: clampToRange(carried, unit, axisPx, allowZero) };
  }

  function selectNumberInput(event: FocusEvent): void {
    const input = event.currentTarget;
    if (input instanceof HTMLInputElement) input.select();
  }
</script>

<!-- Hidden loader so the W/H maxes track the running image even when origin is off
     (the visible minimap reuses the same — cached — preview). -->
<img class="dims-probe" src={previewSrc} alt="" aria-hidden="true" onload={onDimsLoad} />

{#snippet lenControl(
  label: string,
  len: TwicLen,
  axisPx: number,
  allowZero: boolean,
  apply: (next: TwicLen) => void,
)}
  {@const range = unitRange(len.unit, axisPx, allowZero)}
  <div class="dim-control">
    <label class="value-row">
      <span>{label}</span>
      <span class="value-controls">
        <input
          type="number"
          min={range.min}
          max={range.max}
          step={range.step}
          value={len.value}
          aria-label={`${label} value`}
          onfocus={selectNumberInput}
          oninput={(e) => apply(setLen(len, e.currentTarget.valueAsNumber, axisPx, allowZero))}
        />
        <span class="unit-suffix">{range.suffix}</span>
        <select
          class="dim-unit"
          value={len.unit}
          aria-label={`${label} unit`}
          onchange={(e) =>
            apply(changeUnit(len, e.currentTarget.value as TwicLenUnit, axisPx, allowZero))}
        >
          <option value="px">px</option>
          <option value="p">%</option>
          <option value="s">scale</option>
        </select>
      </span>
    </label>

    <Slider.Root
      class="slider-root"
      type="single"
      min={range.min}
      max={range.max}
      step={range.step}
      value={Math.min(Math.max(len.value, range.min), range.max)}
      onValueChange={(v) => apply(setLen(len, v, axisPx, allowZero))}
      onValueCommit={(v) => apply(setLen(len, v, axisPx, allowZero))}
    >
      <Slider.Range class="slider-range" />
      <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
    </Slider.Root>
  </div>
{/snippet}

{@render lenControl("Width", width, runningWidth, false, (next) => (width = next))}
{@render lenControl("Height", height, runningHeight, false, (next) => (height = next))}

<label class="switch-field">
  <Switch.Root class="switch-root" checked={origin !== null} onCheckedChange={toggleOrigin}>
    <Switch.Thumb class="switch-thumb" />
  </Switch.Root>
  <span>Origin (@ XxY)</span>
</label>

{#if origin !== null}
  <TwicCropOriginPicker {previewSrc} {width} {height} bind:x={origin.x} bind:y={origin.y} />
{/if}

<style>
  .dims-probe {
    position: absolute;
    width: 0;
    height: 0;
    opacity: 0;
    pointer-events: none;
  }

  /* Crop dimension control — value + unit dropdown + slider, matching the resize
     dimension control above it. */
  .dim-control {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .value-row,
  .value-controls {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .value-row {
    justify-content: space-between;
  }

  .dim-control input[type="number"] {
    width: auto;
    min-width: 5ch;
    max-width: 10ch;
    border: 1px solid transparent;
    border-radius: 6px;
    background: transparent;
    color: var(--text-primary);
    field-sizing: content;
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 18px;
    padding-inline: 4px;
    text-align: right;
    appearance: textfield;
    -moz-appearance: textfield;

    &::-webkit-inner-spin-button,
    &::-webkit-outer-spin-button {
      margin: 0;
      appearance: none;
      -webkit-appearance: none;
    }

    &:hover,
    &:focus {
      border-color: var(--border-strong);
      background: var(--surface-control);
      outline: none;
    }
  }

  .unit-suffix {
    width: 14px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    text-align: left;
  }

  .dim-unit {
    width: 84px;
    min-height: 32px;
    height: 32px;
    padding-inline: 8px 28px;
    background-position:
      calc(100% - 13px) 14px,
      calc(100% - 8px) 14px;
  }

  .dim-control :global(.slider-root) {
    position: relative;
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    touch-action: none;
    user-select: none;
  }

  .dim-control :global(.slider-root::before) {
    content: "";
    position: absolute;
    inset: 11px 0;
    border-radius: 999px;
    background: var(--surface-control-track);
  }

  .dim-control :global(.slider-range) {
    position: absolute;
    height: 6px;
    border-radius: 999px;
    background: var(--accent);
  }

  .dim-control :global(.slider-thumb) {
    width: 20px;
    height: 20px;
    border: 2px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--text-primary);
  }

  .dim-control :global(.slider-thumb:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>

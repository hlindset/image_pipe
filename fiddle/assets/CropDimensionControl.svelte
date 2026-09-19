<script lang="ts">
  import { Slider } from "bits-ui";
  import { controlLimits, type CropDimensionUnit } from "./api-controls";

  type Props = {
    label: string;
    unit?: CropDimensionUnit;
    pixels: number;
    percent: number;
    maxPixels?: number;
  };

  let {
    label,
    unit = $bindable("px"),
    pixels = $bindable(),
    percent = $bindable(),
    maxPixels = 1200,
  }: Props = $props();

  const activeValue = $derived(unit === "percent" ? percent : pixels);
  const min = $derived(unit === "percent" ? controlLimits.crop.percent.min : 1);
  const max = $derived(unit === "percent" ? controlLimits.crop.percent.max : maxPixels);
  const suffix = $derived(unit === "percent" ? "%" : "px");

  function clamp(value: number): number {
    return Math.min(Math.max(value, min), max);
  }

  function sliderPosition(value: number): number {
    return clamp(value);
  }

  function selectNumber(event: FocusEvent): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement) {
      input.select();
    }
  }

  function setActiveValue(nextValue: number): void {
    const clamped = clamp(nextValue);

    if (unit === "percent") {
      percent = clamped;
    } else if (unit === "px") {
      pixels = clamped;
    }
  }

  function syncNumber(event: Event): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement && !Number.isNaN(input.valueAsNumber)) {
      setActiveValue(input.valueAsNumber);
    }
  }
</script>

<div class="crop-dimension-control">
  <label class="value-row">
    <span>{label}</span>
    <span class="value-controls">
      {#if unit !== "full"}
        <input
          type="number"
          {min}
          {max}
          step={1}
          value={activeValue}
          aria-label={`${label} value`}
          onfocus={selectNumber}
          oninput={syncNumber}
        />
        <span class="unit-suffix">{suffix}</span>
      {/if}
      <select bind:value={unit} aria-label={`${label} unit`}>
        <option value="px">px</option>
        <option value="percent">%</option>
        <option value="full">full</option>
      </select>
    </span>
  </label>

  {#if unit !== "full"}
    <Slider.Root
      class="slider-root"
      type="single"
      {min}
      {max}
      step={1}
      value={sliderPosition(activeValue)}
      onValueChange={setActiveValue}
      onValueCommit={setActiveValue}
    >
      <Slider.Range class="slider-range" />
      <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
    </Slider.Root>
  {/if}
</div>

<style>
  .crop-dimension-control {
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

  input[type="number"] {
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
    width: 18px;
    color: var(--text-muted);
    font-family: var(--font-mono);
    text-align: left;
  }

  select {
    width: 74px;
    min-height: 32px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    font: inherit;
    padding: 0 8px;
  }

  .crop-dimension-control :global(.slider-root) {
    position: relative;
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    touch-action: none;
    user-select: none;
  }

  .crop-dimension-control :global(.slider-root::before) {
    content: "";
    position: absolute;
    inset: 11px 0;
    border-radius: 999px;
    background: var(--surface-control-track);
  }

  .crop-dimension-control :global(.slider-range) {
    position: absolute;
    height: 6px;
    border-radius: 999px;
    background: var(--accent);
  }

  .crop-dimension-control :global(.slider-thumb) {
    width: 20px;
    height: 20px;
    border: 2px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--text-primary);
  }

  .crop-dimension-control :global(.slider-thumb:focus-visible),
  select:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>

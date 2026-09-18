<script lang="ts">
  import { Slider } from "bits-ui";

  type Props = {
    label: string;
    value: number;
    min?: number;
    max?: number;
    step?: number;
    inputStep?: number | "any";
    suffix?: string | undefined;
    // Optional callback for controlled usage (when bind:value isn't available).
    onValueChange?: ((value: number) => void) | undefined;
  };

  let {
    label,
    value = $bindable(),
    min = 0,
    max = 100,
    step = 1,
    inputStep = step,
    suffix = undefined,
    onValueChange = undefined,
  }: Props = $props();

  let decimalInputValue = $state(String(value));
  let editingDecimalInput = $state(false);

  $effect(() => {
    if (!editingDecimalInput) {
      decimalInputValue = String(value);
    }
  });

  function clamp(value: number): number {
    return Math.min(Math.max(value, min), max);
  }

  function sliderPosition(value: number): number {
    const clamped = clamp(value);
    const rounded = min + Math.round((clamped - min) / step) * step;

    return clamp(Number(rounded.toFixed(12)));
  }

  function selectNumber(event: FocusEvent): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement) {
      input.select();
    }
  }

  function syncNumber(event: Event): void {
    const input = event.currentTarget;

    if (input instanceof HTMLInputElement && !Number.isNaN(input.valueAsNumber)) {
      value = clamp(input.valueAsNumber);
      onValueChange?.(value);
    }
  }

  function syncDecimalInput(event: Event): void {
    const input = event.currentTarget;

    if (!(input instanceof HTMLInputElement)) {
      return;
    }

    decimalInputValue = input.value;
  }

  function parseDecimalInput(input: string): number | null {
    const trimmed = input.trim();

    if (trimmed === "") {
      return null;
    }

    const normalized = trimmed.replace(",", ".");

    if (!/^-?\d*(?:\.\d*)?$/.test(normalized) || normalized === ".") {
      return null;
    }

    const parsed = Number.parseFloat(normalized);

    return Number.isFinite(parsed) ? parsed : null;
  }

  function commitDecimalInput(event: FocusEvent): void {
    editingDecimalInput = false;
    const input = event.currentTarget;

    if (!(input instanceof HTMLInputElement)) {
      return;
    }

    const parsed = parseDecimalInput(input.value);

    if (parsed !== null) {
      value = clamp(parsed);
      onValueChange?.(value);
    }

    decimalInputValue = String(value);
  }

  function commitDecimalInputKey(event: KeyboardEvent): void {
    if (event.key !== "Enter") {
      return;
    }

    const input = event.currentTarget;

    if (input instanceof HTMLInputElement) {
      input.blur();
    }
  }

  function selectDecimalInput(event: FocusEvent): void {
    editingDecimalInput = true;
    selectNumber(event);
  }

  function syncSlider(nextValue: number): void {
    editingDecimalInput = false;
    value = clamp(nextValue);
    onValueChange?.(value);
  }
</script>

<div class="range-number">
  <label class="value-row">
    <span>{label}</span>
    <span class="value-input">
      {#if inputStep === "any"}
        <input
          type="text"
          inputmode="decimal"
          value={decimalInputValue}
          onblur={commitDecimalInput}
          onfocus={selectDecimalInput}
          oninput={syncDecimalInput}
          onkeydown={commitDecimalInputKey}
        />
      {:else}
        <input
          type="number"
          {min}
          {max}
          step={inputStep}
          {value}
          onfocus={selectNumber}
          oninput={syncNumber}
        />
      {/if}
      {#if suffix !== undefined}
        <span class="value-suffix">{suffix}</span>
      {/if}
    </span>
  </label>
  <Slider.Root
    class="slider-root"
    type="single"
    {min}
    {max}
    {step}
    value={sliderPosition(value)}
    onValueChange={syncSlider}
    onValueCommit={syncSlider}
  >
    <Slider.Range class="slider-range" />
    <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
  </Slider.Root>
</div>

<style>
  .range-number {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .value-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }

  .value-input {
    display: inline-flex;
    align-items: baseline;
    gap: 2px;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-size: 13px;
    line-height: 18px;
  }

  .value-suffix {
    min-width: 2ch;
    color: var(--text-muted);
  }

  input[type="number"],
  input[type="text"] {
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
  }

  input[type="number"] {
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

  input[type="text"]:hover,
  input[type="text"]:focus {
    border-color: var(--border-strong);
    background: var(--surface-control);
    outline: none;
  }

  .range-number :global(.slider-root) {
    position: relative;
    width: 100%;
    height: 28px;
    display: flex;
    align-items: center;
    touch-action: none;
    user-select: none;
  }

  .range-number :global(.slider-root::before) {
    content: "";
    position: absolute;
    inset: 11px 0;
    border-radius: 999px;
    background: var(--surface-control-track);
  }

  .range-number :global(.slider-range) {
    position: absolute;
    height: 6px;
    border-radius: 999px;
    background: var(--accent);
  }

  .range-number :global(.slider-thumb) {
    width: 20px;
    height: 20px;
    border: 2px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--text-primary);
  }

  .range-number :global(.slider-thumb:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>

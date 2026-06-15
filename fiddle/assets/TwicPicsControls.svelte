<script lang="ts">
  import { SortableList, sortItems } from "@rodrigodagostino/svelte-sortable-list";
  import "@rodrigodagostino/svelte-sortable-list/styles.css";
  import { DropdownMenu, Slider } from "bits-ui";
  import type { TransitionConfig } from "svelte/transition";
  import ImagePointPicker from "./ImagePointPicker.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import TwicCropControls from "./TwicCropControls.svelte";
  import { type SourceImage } from "./processing-path";
  import {
    defaultStep,
    nextStepId,
    setResizeAxisUnit,
    stepSummary,
    twicFetchPath,
    twicOutputs,
    type TransformStep,
    type TransformType,
    type TwicAnchor,
    type TwicPicsState,
    type TwicRelUnit,
    type TwicResizeUnit,
  } from "./twicpics-path";

  type Props = {
    twicpicsState: TwicPicsState;
    source: SourceImage;
  };

  let { twicpicsState = $bindable(), source: _source }: Props = $props();

  // Which cards are expanded. New cards open by default; parsed/reloaded cards are
  // collapsed (falsy) and show their summary.
  let openCards = $state<Record<string, boolean>>({});

  const transformTypes: { type: TransformType; label: string }[] = [
    { type: "resize", label: "resize" },
    { type: "cover", label: "cover" },
    { type: "contain", label: "contain" },
    { type: "inside", label: "inside" },
    { type: "crop", label: "crop" },
    { type: "focus", label: "focus" },
  ];

  // 3x3 anchor grid (center cell is null — TwicPics has no center anchor).
  const anchorGrid: (TwicAnchor | null)[] = [
    "top-left",
    "top",
    "top-right",
    "left",
    null,
    "right",
    "bottom-left",
    "bottom",
    "bottom-right",
  ];
  const anchorGlyph: Record<TwicAnchor, string> = {
    "top-left": "↖",
    top: "↑",
    "top-right": "↗",
    left: "←",
    right: "→",
    "bottom-left": "↙",
    bottom: "↓",
    "bottom-right": "↘",
  };

  // Per-unit slider range + suffix for a resize dimension.
  function resizeRange(unit: TwicResizeUnit): {
    min: number;
    max: number;
    step: number;
    suffix: string;
  } {
    switch (unit) {
      case "p":
        return { min: 1, max: 300, step: 1, suffix: "%" };
      case "s":
        return { min: 0.1, max: 4, step: 0.1, suffix: "×" };
      default:
        return { min: 1, max: 4000, step: 1, suffix: "px" };
    }
  }

  // Suppress the library's default scale/fly in+out transitions: pre-existing chain
  // items were animating in on load (and a transient duplicate fading out). Reorder
  // movement (the library's CSS transition) is unaffected.
  const instant = (): TransitionConfig => ({ duration: 0 });

  function addStep(type: TransformType): void {
    const step = defaultStep(type, nextStepId());
    twicpicsState.chain = [...twicpicsState.chain, step];
    openCards[step.id] = true;
  }

  function removeStep(id: string): void {
    twicpicsState.chain = twicpicsState.chain.filter((step) => step.id !== id);
  }

  function toggleCard(id: string): void {
    openCards[id] = !openCards[id];
  }

  function handleDragEnd(event: {
    draggedItemIndex: number;
    targetItemIndex: number | null;
    isCanceled: boolean;
  }): void {
    if (event.isCanceled || event.targetItemIndex === null) return;
    twicpicsState.chain = sortItems(
      twicpicsState.chain,
      event.draggedItemIndex,
      event.targetItemIndex,
    );
  }

  function selectNumberInput(event: FocusEvent): void {
    const input = event.currentTarget;
    if (input instanceof HTMLInputElement) input.select();
  }

  function setResizeValue(
    step: Extract<TransformStep, { type: "resize" }>,
    axis: "w" | "h",
    value: number,
  ): void {
    if (Number.isNaN(value)) return;
    const { min, max, step: stepSize } = resizeRange(step[axis].unit);
    const clamped = Math.min(Math.max(value, min), max);
    // Snap to the unit's step precision so float drift from the slider doesn't
    // surface as e.g. `resize=0.7000000000000001s` in the URL (scale = 1 decimal,
    // px/% = integer).
    const factor = stepSize < 1 ? 10 : 1;
    step[axis] = { unit: step[axis].unit, value: Math.round(clamped * factor) / factor };
  }

  // Switch a resize axis unit (keeps the both-auto guard in setResizeAxisUnit), then
  // clamp the carried value into the new unit's range.
  function changeResizeUnit(
    step: Extract<TransformStep, { type: "resize" }>,
    axis: "w" | "h",
    unit: TwicResizeUnit,
  ): void {
    setResizeAxisUnit(step, axis, unit);
    if (step[axis].unit !== "auto") setResizeValue(step, axis, step[axis].value);
  }

  // --- focus ---

  type FocusStep = Extract<TransformStep, { type: "focus" }>;

  function focusMode(step: FocusStep): "anchor" | "coord" {
    return step.mode;
  }

  // Switch a focus card between the 8-anchor grid and a relative coordinate. The
  // parser rejects bare-pixel and auto/center focus, so the coordinate mode is
  // relative-only (p/s) and never offers those.
  function setFocusMode(step: FocusStep, mode: "anchor" | "coord", index: number): void {
    if (mode === step.mode) return;
    twicpicsState.chain[index] =
      mode === "anchor"
        ? { type: "focus", id: step.id, mode: "anchor", anchor: "top" }
        : {
            type: "focus",
            id: step.id,
            mode: "coord",
            x: { unit: "p", value: 50 },
            y: { unit: "p", value: 50 },
          };
  }

  // Per-unit range + suffix for a relative focus coordinate. In-range only: the
  // parser rejects ratio > 1 (max 100% / 1×).
  function focusRange(unit: TwicRelUnit): { max: number; step: number; suffix: string } {
    return unit === "s" ? { max: 1, step: 0.01, suffix: "×" } : { max: 100, step: 1, suffix: "%" };
  }

  function roundFocus(value: number, unit: TwicRelUnit): number {
    const factor = unit === "s" ? 100 : 1;
    return Math.round(value * factor) / factor;
  }

  function clampFocus(value: number, unit: TwicRelUnit): number {
    const { max } = focusRange(unit);
    return roundFocus(Math.min(Math.max(value, 0), max), unit);
  }

  function setFocusAxis(
    step: Extract<FocusStep, { mode: "coord" }>,
    axis: "x" | "y",
    value: number,
  ): void {
    if (Number.isNaN(value)) return;
    step[axis] = { unit: step[axis].unit, value: clampFocus(value, step[axis].unit) };
  }

  function changeFocusUnit(
    step: Extract<FocusStep, { mode: "coord" }>,
    axis: "x" | "y",
    unit: TwicRelUnit,
  ): void {
    // Preserve the on-image fraction across the unit switch (50% <-> 0.5×).
    const range = focusRange(step[axis].unit);
    const fraction = step[axis].value / range.max;
    const next = focusRange(unit).max * fraction;
    step[axis] = { unit, value: clampFocus(next, unit) };
  }

  // Map a normalized minimap point (0..1) to both relative coordinates at once.
  function pickFocus(step: Extract<FocusStep, { mode: "coord" }>, nx: number, ny: number): void {
    step.x = {
      unit: step.x.unit,
      value: clampFocus(nx * focusRange(step.x.unit).max, step.x.unit),
    };
    step.y = {
      unit: step.y.unit,
      value: clampFocus(ny * focusRange(step.y.unit).max, step.y.unit),
    };
  }

  function focusMarker(len: { unit: TwicRelUnit; value: number }): number {
    return len.value / focusRange(len.unit).max;
  }
</script>

{#snippet resizeAxis(
  step: Extract<TransformStep, { type: "resize" }>,
  axis: "w" | "h",
  label: string,
)}
  {@const dim = step[axis]}
  {@const range = resizeRange(dim.unit)}
  <div class="dim-control">
    <label class="value-row">
      <span>{label}</span>
      <span class="value-controls">
        {#if dim.unit !== "auto"}
          <input
            type="number"
            min={range.min}
            max={range.max}
            step={range.step}
            value={dim.value}
            aria-label={`${label} value`}
            onfocus={selectNumberInput}
            oninput={(e) => setResizeValue(step, axis, e.currentTarget.valueAsNumber)}
          />
          <span class="unit-suffix">{range.suffix}</span>
        {/if}
        <select
          class="dim-unit"
          value={dim.unit}
          aria-label={`${label} unit`}
          onchange={(e) => changeResizeUnit(step, axis, e.currentTarget.value as TwicResizeUnit)}
        >
          <option value="px">px</option>
          <option value="p">%</option>
          <option value="s">scale</option>
          <option value="auto">auto</option>
        </select>
      </span>
    </label>

    {#if dim.unit !== "auto"}
      <Slider.Root
        class="slider-root"
        type="single"
        min={range.min}
        max={range.max}
        step={range.step}
        value={Math.min(Math.max(dim.value, range.min), range.max)}
        onValueChange={(v) => setResizeValue(step, axis, v)}
        onValueCommit={(v) => setResizeValue(step, axis, v)}
      >
        <Slider.Range class="slider-range" />
        <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
      </Slider.Root>
    {/if}
  </div>
{/snippet}

{#snippet focusAxis(
  step: Extract<TransformStep, { type: "focus"; mode: "coord" }>,
  axis: "x" | "y",
  label: string,
)}
  {@const len = step[axis]}
  {@const range = focusRange(len.unit)}
  <div class="dim-control">
    <label class="value-row">
      <span>{label}</span>
      <span class="value-controls">
        <input
          type="number"
          min={0}
          max={range.max}
          step={range.step}
          value={len.value}
          aria-label={`${label} value`}
          onfocus={selectNumberInput}
          oninput={(e) => setFocusAxis(step, axis, e.currentTarget.valueAsNumber)}
        />
        <span class="unit-suffix">{range.suffix}</span>
        <select
          class="dim-unit"
          value={len.unit}
          aria-label={`${label} unit`}
          onchange={(e) => changeFocusUnit(step, axis, e.currentTarget.value as TwicRelUnit)}
        >
          <option value="p">%</option>
          <option value="s">scale</option>
        </select>
      </span>
    </label>

    <Slider.Root
      class="slider-root"
      type="single"
      min={0}
      max={range.max}
      step={range.step}
      value={Math.min(Math.max(len.value, 0), range.max)}
      onValueChange={(v) => setFocusAxis(step, axis, v)}
      onValueCommit={(v) => setFocusAxis(step, axis, v)}
    >
      <Slider.Range class="slider-range" />
      <Slider.Thumb class="slider-thumb" index={0} aria-label={`${label} slider`} />
    </Slider.Root>
  </div>
{/snippet}

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Transform chain</h2>
    </div>
  </div>

  {#if twicpicsState.chain.length === 0}
    <p class="chain-empty">No transforms yet — add one below.</p>
  {/if}

  <SortableList.Root gap={8} ondragend={handleDragEnd}>
    {#each twicpicsState.chain as step, index (step.id)}
      <SortableList.Item id={step.id} {index} transitionIn={instant} transitionOut={instant}>
        <div class="chain-row">
          <SortableList.ItemHandle>
            <span class="drag-handle" aria-hidden="true">⠿</span>
          </SortableList.ItemHandle>
          <div class="chain-card">
            <div class="chain-card-head">
              <button
                type="button"
                class="card-toggle"
                aria-expanded={openCards[step.id] ? "true" : "false"}
                onclick={() => toggleCard(step.id)}
              >
                <span class="card-name">{step.type}</span>
                <span class="card-chevron" aria-hidden="true"></span>
                <span class="card-summary">{stepSummary(step)}</span>
              </button>
              <SortableList.ItemRemove
                class="card-remove"
                aria-label={`Remove ${step.type}`}
                onclick={() => removeStep(step.id)}
              >
                ×
              </SortableList.ItemRemove>
            </div>

            {#if openCards[step.id]}
              <div class="chain-card-body">
                {#if step.type === "resize"}
                  {@render resizeAxis(step, "w", "Width")}
                  {@render resizeAxis(step, "h", "Height")}
                {:else if step.type === "cover"}
                  <label class="field">
                    <span>Mode</span>
                    <select bind:value={step.mode}>
                      <option value="size">size (WxH px)</option>
                      <option value="ratio">ratio (W:H)</option>
                    </select>
                  </label>
                  <RangeNumber
                    label={step.mode === "ratio" ? "W" : "Width"}
                    bind:value={step.w}
                    min={1}
                    max={8000}
                    step={1}
                  />
                  <RangeNumber
                    label={step.mode === "ratio" ? "H" : "Height"}
                    bind:value={step.h}
                    min={1}
                    max={8000}
                    step={1}
                  />
                {:else if step.type === "contain" || step.type === "inside"}
                  <RangeNumber
                    label="Width"
                    bind:value={step.w}
                    min={1}
                    max={8000}
                    step={1}
                    suffix="px"
                  />
                  <RangeNumber
                    label="Height"
                    bind:value={step.h}
                    min={1}
                    max={8000}
                    step={1}
                    suffix="px"
                  />
                {:else if step.type === "crop"}
                  {@const cropPreviewSrc = twicFetchPath({
                    source: twicpicsState.source,
                    chain: twicpicsState.chain.slice(0, index),
                    output: "jpeg",
                    quality: 80,
                  })}
                  <TwicCropControls
                    previewSrc={cropPreviewSrc}
                    bind:width={step.w}
                    bind:height={step.h}
                    bind:origin={step.origin}
                  />
                {:else if step.type === "focus"}
                  <div class="focus-mode" role="group" aria-label="Focus mode">
                    <button
                      type="button"
                      class="focus-mode-tab"
                      aria-pressed={focusMode(step) === "anchor" ? "true" : "false"}
                      onclick={() => setFocusMode(step, "anchor", index)}
                    >
                      Anchor
                    </button>
                    <button
                      type="button"
                      class="focus-mode-tab"
                      aria-pressed={focusMode(step) === "coord" ? "true" : "false"}
                      onclick={() => setFocusMode(step, "coord", index)}
                    >
                      Coordinate
                    </button>
                  </div>

                  {#if step.mode === "anchor"}
                    <div class="anchor-grid" role="group" aria-label="Focus anchor">
                      {#each anchorGrid as cell}
                        {#if cell === null}
                          <span class="anchor-cell anchor-cell-empty" aria-hidden="true"></span>
                        {:else}
                          <button
                            type="button"
                            class="anchor-cell"
                            aria-pressed={step.anchor === cell ? "true" : "false"}
                            aria-label={cell}
                            onclick={() => (step.anchor = cell)}
                          >
                            {anchorGlyph[cell]}
                          </button>
                        {/if}
                      {/each}
                    </div>
                  {:else}
                    {@const focusPreviewSrc = twicFetchPath({
                      source: twicpicsState.source,
                      chain: twicpicsState.chain.slice(0, index),
                      output: "jpeg",
                      quality: 80,
                    })}
                    {@const xRange = focusRange(step.x.unit)}
                    {@const yRange = focusRange(step.y.unit)}
                    <ImagePointPicker
                      src={focusPreviewSrc}
                      markerX={focusMarker(step.x)}
                      markerY={focusMarker(step.y)}
                      ariaLabel={`Set focus point, currently ${step.x.value}${xRange.suffix}, ${step.y.value}${yRange.suffix}`}
                      onPick={(nx, ny) => pickFocus(step, nx, ny)}
                    />

                    {@render focusAxis(step, "x", "X")}
                    {@render focusAxis(step, "y", "Y")}
                  {/if}
                {/if}
              </div>
            {/if}
          </div>
        </div>
      </SortableList.Item>
    {/each}
  </SortableList.Root>

  <DropdownMenu.Root>
    <DropdownMenu.Trigger class="twic-add-trigger">
      + Add transform
      <span class="twic-add-chevron" aria-hidden="true"></span>
    </DropdownMenu.Trigger>
    <DropdownMenu.Content class="twic-menu-content" sideOffset={4} align="start">
      {#each transformTypes as item}
        <DropdownMenu.Item class="twic-menu-item" onSelect={() => addStep(item.type)}>
          {item.label}
        </DropdownMenu.Item>
      {/each}
    </DropdownMenu.Content>
  </DropdownMenu.Root>
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Output</h2>
      <p>{twicpicsState.output} · q{twicpicsState.quality}</p>
    </div>
  </div>

  <label class="field">
    <span>Format</span>
    <select bind:value={twicpicsState.output}>
      {#each twicOutputs as format}
        <option value={format}>{format}</option>
      {/each}
    </select>
  </label>

  <RangeNumber label="Quality" bind:value={twicpicsState.quality} min={1} max={100} step={1} />
</section>

<style>
  .chain-empty {
    margin: 0 0 8px;
    color: var(--text-muted);
    font-size: 13px;
  }

  /* The drag handle is absolutely positioned in the gutter (see below), so it takes
     no layout space and the card spans the full lane width, flush to the left. */
  .chain-row {
    position: relative;
    /* Retheme the library's handle/remove buttons (they default to their own gray
       scale): no background, one color, opacity-only hover. */
    --ssl-gray-400: var(--text-primary);
    --ssl-gray-150: transparent;
    --ssl-gray-700: var(--text-primary);
  }

  .chain-card {
    /* Same surface as the sidebar it sits on; the border delineates the card so the
       inner control surfaces (inputs, slider tracks) clearly stand out against it. */
    background: var(--surface-sidebar);
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    overflow: hidden;
  }

  .chain-card-head {
    min-height: 42px;
    box-sizing: border-box;
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 6px;
  }

  /* Handle lives in the left gutter (outside the card); remove stays inside the head.
     Both: the library pulls them out by -1rem — reset that — with no background in
     any state, just an opacity fade on hover/focus. */
  .chain-row :global(.ssl-item-handle),
  .chain-row :global(.ssl-item-remove) {
    margin: 0;
    padding: 6px;
    border-radius: 6px;
    background: transparent;
    cursor: pointer;
    opacity: 0.5;
    transition: opacity 120ms ease;
  }

  .chain-row :global(.ssl-item-handle:hover),
  .chain-row :global(.ssl-item-handle:focus-visible),
  .chain-row :global(.ssl-item-remove:hover),
  .chain-row :global(.ssl-item-remove:focus-visible) {
    opacity: 1;
  }

  /* Float in the gutter to the left of the card (no layout space), spanning the
     collapsed card height (header + border) with the grip centered; it stays by the
     header when the card expands taller. No internal padding, so the grip glyph
     itself is the full hit/visual area. */
  .chain-row :global(.ssl-item-handle) {
    position: absolute;
    top: 0;
    right: 100%;
    margin-right: 8px;
    height: 44px;
    padding: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: grab;
  }

  .drag-handle {
    display: inline-flex;
    font-size: 20px;
    line-height: 1;
  }

  .card-toggle {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 8px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    text-align: start;
    padding: 6px 4px;
  }

  .card-chevron {
    width: 7px;
    height: 7px;
    flex-shrink: 0;
    border-inline-end: 2px solid var(--text-muted);
    border-block-end: 2px solid var(--text-muted);
    transform: rotate(45deg) translate(-1px, -1px);
    transition: transform 150ms ease;
  }

  .card-toggle[aria-expanded="false"] .card-chevron {
    transform: rotate(-45deg);
  }

  .card-name {
    font-weight: 700;
    font-size: 13px;
  }

  .card-summary {
    min-width: 0;
    /* Pushed to the trailing edge of the toggle: name + chevron sit left, the
       params readout sits right, just before the remove button. */
    margin-inline-start: auto;
    padding-inline-start: 8px;
    overflow: hidden;
    color: var(--text-muted);
    font-family: var(--font-mono);
    font-size: 12px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chain-card :global(.card-remove) {
    font-size: 18px;
    line-height: 1;
  }

  .chain-card-body {
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 12px;
    border-block-start: 1px solid var(--border-subtle);
  }

  /* Resize dimension control — value + unit dropdown + slider (slider hidden when
     the unit is "auto"), matching the imgproxy crop/resize dimension controls. */
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

  .focus-mode {
    display: inline-flex;
    gap: 4px;
    padding: 3px;
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-control);
    align-self: flex-start;
  }

  .focus-mode-tab {
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    padding: 4px 12px;
  }

  .focus-mode-tab[aria-pressed="true"] {
    background: var(--accent);
    color: var(--surface-sidebar);
  }

  .focus-mode-tab:focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .anchor-grid {
    display: grid;
    grid-template-columns: repeat(3, 36px);
    grid-auto-rows: 36px;
    gap: 4px;
  }

  .anchor-cell {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-strong);
    border-radius: 6px;
    background: var(--surface-control);
    color: var(--text-primary);
    cursor: pointer;
    font-size: 16px;
    line-height: 1;
  }

  .anchor-cell[aria-pressed="true"] {
    border-color: var(--accent);
    background: var(--accent);
    color: var(--surface-sidebar);
  }

  .anchor-cell-empty {
    border: 1px dashed var(--border-subtle);
    border-radius: 6px;
    cursor: default;
  }

  /* "+ Add transform" dropdown (bits-ui), mirroring the obj-class Select styling. */
  :global(.twic-add-trigger) {
    width: 100%;
    height: 38px;
    margin-block-start: 10px;
    display: inline-flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    padding-inline: 12px 10px;
    font: inherit;
    font-size: 14px;
    line-height: 18px;
    cursor: pointer;
    text-align: start;
  }

  :global(.twic-add-trigger:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .twic-add-chevron {
    width: 5px;
    height: 5px;
    flex-shrink: 0;
    border-inline-end: 2px solid var(--text-muted);
    border-block-end: 2px solid var(--text-muted);
    transform: rotate(45deg) translate(-1px, -1px);
    margin-inline-end: 4px;
  }

  :global(.twic-add-trigger[data-state="open"]) .twic-add-chevron {
    transform: rotate(-135deg) translate(-1px, -1px);
  }

  :global(.twic-menu-content) {
    min-width: var(--bits-dropdown-menu-anchor-width, 180px);
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-sidebar);
    box-shadow: var(--image-shadow);
    overflow: hidden;
    padding: 4px;
    z-index: 50;
  }

  :global(.twic-menu-item) {
    height: 32px;
    display: flex;
    align-items: center;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    padding-inline: 8px;
    width: 100%;
    text-align: start;
  }

  :global(.twic-menu-item:hover),
  :global(.twic-menu-item[data-highlighted]) {
    background: color-mix(in srgb, var(--accent) 12%, var(--surface-control));
    color: var(--text-heading);
  }

  /* Keep the sortable list flush with the surrounding panel. */
  .tool-section :global(.ssl-list) {
    padding: 0;
  }
</style>

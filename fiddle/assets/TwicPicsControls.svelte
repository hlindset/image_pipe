<script lang="ts">
  import { SortableList, sortItems } from "@rodrigodagostino/svelte-sortable-list";
  import "@rodrigodagostino/svelte-sortable-list/styles.css";
  import { DropdownMenu } from "bits-ui";
  import type { TransitionConfig } from "svelte/transition";
  import RangeNumber from "./RangeNumber.svelte";
  import { type SourceImage } from "./processing-path";
  import {
    defaultStep,
    nextStepId,
    setResizeAxisUnit,
    stepSummary,
    twicOutputs,
    type TransformStep,
    type TransformType,
    type TwicAnchor,
    type TwicPicsState,
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

  const resizeUnits: { value: TwicResizeUnit; label: string }[] = [
    { value: "px", label: "px" },
    { value: "p", label: "%" },
    { value: "s", label: "scale" },
    { value: "auto", label: "auto" },
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

  // Suppress the library's default scale/fly intro so pre-existing chain items
  // don't animate in on load (the "falls down then snaps" effect). Reorder/remove
  // animations are left to the library's defaults.
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

  function toggleCropOrigin(step: Extract<TransformStep, { type: "crop" }>, on: boolean): void {
    step.origin = on ? { x: 1, y: 1 } : null;
  }
</script>

{#snippet resizeAxis(
  step: Extract<TransformStep, { type: "resize" }>,
  axis: "w" | "h",
  label: string,
)}
  <div class="field">
    <span>{label}</span>
    <div class="resize-axis">
      <select
        value={step[axis].unit}
        onchange={(e) => setResizeAxisUnit(step, axis, e.currentTarget.value as TwicResizeUnit)}
      >
        {#each resizeUnits as unit}
          <option value={unit.value}>{unit.label}</option>
        {/each}
      </select>
      {#if step[axis].unit !== "auto"}
        <input
          class="text-input resize-value"
          type="number"
          min="1"
          step={step[axis].unit === "s" ? "any" : "1"}
          bind:value={step[axis].value}
        />
      {/if}
    </div>
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
      <SortableList.Item id={step.id} {index} transitionIn={instant}>
        <div class="chain-card">
          <div class="chain-card-head">
            <SortableList.ItemHandle>
              <span class="drag-handle" aria-hidden="true">⠿</span>
            </SortableList.ItemHandle>
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
                <label class="switch-field">
                  <input
                    type="checkbox"
                    checked={step.origin !== null}
                    onchange={(e) => toggleCropOrigin(step, e.currentTarget.checked)}
                  />
                  <span>Origin (@ XxY)</span>
                </label>
                {#if step.origin !== null}
                  <RangeNumber
                    label="X"
                    bind:value={step.origin.x}
                    min={1}
                    max={8000}
                    step={1}
                    suffix="px"
                  />
                  <RangeNumber
                    label="Y"
                    bind:value={step.origin.y}
                    min={1}
                    max={8000}
                    step={1}
                    suffix="px"
                  />
                {/if}
              {:else if step.type === "focus"}
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
              {/if}
            </div>
          {/if}
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

  .chain-card {
    /* A lighter gray than BOTH inner control surfaces — the inputs/selects
       (--surface-control) and the slider tracks (--surface-control-track) — so they
       read as recessed against it (mixing toward the text color keeps it distinct in
       light and dark themes alike). Also retheme the library's handle/remove buttons,
       which default to their own gray scale: no hover background, one color, and an
       opacity-only hover (see below). */
    background: color-mix(in srgb, var(--surface-control) 82%, var(--text-primary) 18%);
    --ssl-gray-400: var(--text-primary);
    --ssl-gray-150: transparent;
    --ssl-gray-700: var(--text-primary);
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    overflow: hidden;
  }

  .chain-card-head {
    display: flex;
    align-items: center;
    gap: 2px;
    padding: 6px;
  }

  /* The library pulls the handle/remove out by -1rem (assumes a 1rem container
     padding); reset so they sit inside our card padding instead of on the border. */
  .chain-card :global(.ssl-item-handle),
  .chain-card :global(.ssl-item-remove) {
    margin: 0;
    padding: 6px;
    border-radius: 6px;
    cursor: pointer;
    opacity: 0.55;
    transition: opacity 120ms ease;
  }

  .chain-card :global(.ssl-item-handle:hover),
  .chain-card :global(.ssl-item-handle:focus-visible),
  .chain-card :global(.ssl-item-remove:hover),
  .chain-card :global(.ssl-item-remove:focus-visible) {
    opacity: 1;
  }

  .chain-card :global(.ssl-item-handle) {
    cursor: grab;
  }

  .drag-handle {
    display: inline-flex;
    font-size: 16px;
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

  .resize-axis {
    display: flex;
    gap: 8px;
  }

  .resize-value {
    width: 96px;
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

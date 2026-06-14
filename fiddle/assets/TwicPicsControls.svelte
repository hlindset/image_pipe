<script lang="ts">
  import { SortableList, sortItems } from "@rodrigodagostino/svelte-sortable-list";
  import "@rodrigodagostino/svelte-sortable-list/styles.css";
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

  function addStep(type: TransformType): void {
    const step = defaultStep(type, nextStepId());
    twicpicsState.chain = [...twicpicsState.chain, step];
    openCards[step.id] = true;
  }

  function onAddSelect(event: Event & { currentTarget: HTMLSelectElement }): void {
    const value = event.currentTarget.value;
    if (value !== "") {
      addStep(value as TransformType);
      event.currentTarget.value = "";
    }
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
      <p>{twicpicsState.chain.length} step{twicpicsState.chain.length === 1 ? "" : "s"}</p>
    </div>
  </div>

  {#if twicpicsState.chain.length === 0}
    <p class="chain-empty">No transforms yet — add one below.</p>
  {/if}

  <SortableList.Root gap={8} ondragend={handleDragEnd}>
    {#each twicpicsState.chain as step, index (step.id)}
      <SortableList.Item id={step.id} {index}>
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

  <label class="field add-transform">
    <span>Add transform</span>
    <select value="" onchange={onAddSelect}>
      <option value="" disabled>+ Add transform…</option>
      {#each transformTypes as item}
        <option value={item.type}>{item.label}</option>
      {/each}
    </select>
  </label>
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
    border: 1px solid var(--border-subtle);
    border-radius: 8px;
    background: var(--surface-control);
    overflow: hidden;
  }

  .chain-card-head {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
  }

  .drag-handle {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 28px;
    color: var(--text-muted);
    cursor: grab;
    font-size: 16px;
    line-height: 1;
  }

  .card-toggle {
    flex: 1;
    min-width: 0;
    display: flex;
    align-items: baseline;
    gap: 8px;
    border: 0;
    background: transparent;
    color: var(--text-primary);
    cursor: pointer;
    text-align: start;
    padding: 4px 2px;
  }

  .card-name {
    font-weight: 700;
    font-size: 13px;
  }

  .card-summary {
    min-width: 0;
    overflow: hidden;
    color: var(--text-muted);
    font-family: var(--font-mono);
    font-size: 12px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .chain-card :global(.card-remove) {
    width: 26px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 6px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    font-size: 18px;
    line-height: 1;
  }

  .chain-card :global(.card-remove:hover) {
    background: var(--surface-button-quiet);
    color: var(--text-heading);
  }

  .chain-card-body {
    display: flex;
    flex-direction: column;
    gap: 10px;
    padding: 8px;
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
  }

  .add-transform {
    margin-block-start: 10px;
  }

  /* Keep the sortable list flush with the surrounding panel. */
  .tool-section :global(.ssl-list) {
    padding: 0;
  }
</style>

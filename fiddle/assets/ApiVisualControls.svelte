<script lang="ts">
  import { Collapsible, Select, Switch, Tabs } from "bits-ui";
  import CropDimensionControl from "./CropDimensionControl.svelte";
  import ImagePointPicker from "./ImagePointPicker.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import ResizeDimensionControl from "./ResizeDimensionControl.svelte";
  import ToolToggleHeader from "./ToolToggleHeader.svelte";
  import {
    cocoClasses,
    controlLimits,
    controlOptionSegments,
    cropPixelLimit,
    resetCropPixelsToSource,
    type ControlState,
    type SourceImage,
  } from "./api-controls";
  let { controlState = $bindable(), source }: { controlState: ControlState; source: SourceImage } =
    $props();
  let orientationOpen = $state(false);
  let scaleOptionsOpen = $state(false);
  let effectsOpen = $state(false);
  let encoderOptionsOpen = $state(false);
  const fiddleObjClassesForPicker = ["face", ...cocoClasses];
  const cropWidthLimit = $derived(cropPixelLimit(source, "width"));
  const cropHeightLimit = $derived(cropPixelLimit(source, "height"));
  function summary(...keys: string[]): string {
    return (
      controlOptionSegments(controlState)
        .filter((segment) => keys.includes(segment.split("=")[0]!))
        .join("/") || "Off"
    );
  }
  const orientationSummary = $derived(summary("orient", "rotate", "flip"));
  const trimSummary = $derived(summary("trim", "trim-symmetry"));
  const resizeSummary = $derived(summary("w", "h", "fit", "extend"));
  const aspectCanvasSummary = $derived(summary("extend-ratio", "extend-at"));
  const paddingSummary = $derived(summary("pad"));
  const backgroundSummary = $derived(summary("bg"));
  const effectsSummary = $derived(
    summary(
      "blur",
      "sharpen",
      "pixelate",
      "monochrome",
      "duotone",
      "brightness",
      "contrast",
      "saturation",
      "colorize",
      "gradient",
    ),
  );
  const metadataSummary = $derived(summary("meta", "profile", "hdr"));
  const autoqualitySummary = $derived(summary("autoquality"));
  const encoderOptionsSummary = $derived(
    summary("jpeg-options", "png-options", "webp-options", "avif-options"),
  );
  const maxBytesSummary = $derived(summary("max-bytes"));
  const cropSummary = $derived(summary("crop"));
  const cropAspectRatioSummary = $derived(summary("crop-ratio", "crop-ratio-enlarge"));
  const resizeExtras = $derived(summary("zoom", "dpr", "min-w", "min-h"));

  function updateCropEnabled(enabled: boolean): void {
    controlState.cropEnabled = enabled;

    if (enabled) {
      controlState = resetCropPixelsToSource(controlState);
    }
  }

  function updateStripMetadata(checked: boolean): void {
    controlState.stripMetadata = checked;

    if (!checked) {
      controlState.keepCopyright = false;
    }
  }

  function syncObjClasses(nextClasses: string[]): void {
    // Add default weight for newly selected classes; remove weight for deselected ones.
    const prev = new Set(controlState.objSelectedClasses);
    const next = new Set(nextClasses);
    let weights = { ...controlState.objWeights };

    for (const cls of next) {
      if (!prev.has(cls)) {
        weights = { ...weights, [cls]: weights[cls] ?? 1 };
      }
    }

    for (const cls of prev) {
      if (!next.has(cls)) {
        const { [cls]: _removed, ...rest } = weights;

        weights = rest;
      }
    }

    controlState.objSelectedClasses = nextClasses;
    controlState.objWeights = weights;
  }

  function objClassTriggerLabel(selected: string[]): string {
    if (selected.length === 0) {
      return "All objects";
    }

    if (selected.length === 1) {
      return selected[0]!;
    }

    return `${selected.length} classes`;
  }

  function setFocalPoint(nx: number, ny: number): void {
    controlState.gravityFocalX = nx;
    controlState.gravityFocalY = ny;
  }

  // Codec encoder options are tri-state per field (unset / on / off / value),
  // so they are driven by selects and number inputs keyed to "" = unset. These
  // helpers translate the select/input value to undefined (unset) or a value,
  // returning a fresh nested object so Svelte reactivity sees the change.
  type TriBool = "" | "on" | "off";

  function triBoolValue(value: boolean | undefined): TriBool {
    if (value === undefined) {
      return "";
    }

    return value ? "on" : "off";
  }

  function fromTriBool(value: string): boolean | undefined {
    if (value === "on") {
      return true;
    }

    if (value === "off") {
      return false;
    }

    return undefined;
  }

  function selectValue<T extends string>(value: T | undefined): "" | T {
    return value ?? "";
  }

  function fromSelectValue<T extends string>(value: string): T | undefined {
    return value === "" ? undefined : (value as T);
  }

  // Canonical bounded integer only — mirrors the backend's `Integer.parse/1`
  // + range check, so the controls never emit a value the URL parser would 400
  // on (e.g. 1.5, 1e2, or out-of-range).
  function fromIntInput(value: string, lo: number, hi: number): number | undefined {
    const trimmed = value.trim();

    if (trimmed === "" || !/^[+-]?\d+$/.test(trimmed)) {
      return undefined;
    }

    const parsed = Number(trimmed);

    return Number.isInteger(parsed) && parsed >= lo && parsed <= hi ? parsed : undefined;
  }
</script>

<section class="tool-section">
  <ToolToggleHeader
    title="Resize"
    summary={resizeSummary}
    bind:checked={controlState.resizeEnabled}
  />

  {#if controlState.resizeEnabled}
    <ResizeDimensionControl
      label="Width"
      bind:unit={controlState.resizeWidthUnit}
      bind:pixels={controlState.width}
      maxPixels={controlLimits.resize.width.max}
    />
    <ResizeDimensionControl
      label="Height"
      bind:unit={controlState.resizeHeightUnit}
      bind:pixels={controlState.height}
      maxPixels={controlLimits.resize.height.max}
    />

    <label class="field">
      <span>Type</span>
      <select bind:value={controlState.resizeMode}>
        <option value="contain">contain</option>
        <option value="cover">cover</option>
        <option value="cover-down">cover-down</option>
        <option value="stretch">stretch</option>
        <option value="auto">auto</option>
      </select>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={controlState.enlarge}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Allow enlargement</span>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={controlState.resizeExtendEnabled}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Extend result</span>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Crop"
    summary={cropSummary}
    checked={controlState.cropEnabled}
    onCheckedChange={updateCropEnabled}
  />

  {#if controlState.cropEnabled}
    <CropDimensionControl
      label="Width"
      bind:unit={controlState.cropWidthUnit}
      bind:pixels={controlState.cropWidth}
      bind:percent={controlState.cropWidthPercent}
      maxPixels={cropWidthLimit.max}
    />
    <CropDimensionControl
      label="Height"
      bind:unit={controlState.cropHeightUnit}
      bind:pixels={controlState.cropHeight}
      bind:percent={controlState.cropHeightPercent}
      maxPixels={cropHeightLimit.max}
    />

    <p class="field-hint">Use Gravity below to position both crop and cover resize.</p>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Crop aspect ratio"
    summary={cropAspectRatioSummary}
    bind:checked={controlState.cropAspectRatioEnabled}
  />

  {#if controlState.cropAspectRatioEnabled}
    <RangeNumber
      label="Ratio"
      bind:value={controlState.cropAspectRatio}
      min={0.1}
      max={10}
      step={0.1}
    />
    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={controlState.cropAspectRatioEnlarge}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Enlarge</span>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Gravity"
    summary={summary("anchor", "anchor-offset", "focus", "detect")}
    bind:checked={controlState.gravityEnabled}
  />

  {#if controlState.gravityEnabled}
    <label class="field">
      <span>Mode</span>
      <select bind:value={controlState.gravityMode}>
        <option value="anchor">anchor</option>
        <option value="focalPoint">focal point</option>
        <option value="offset">anchor + offset</option>
        <option value="smart">smart</option>
        <option value="smartFace">smart + faces</option>
        <option value="objFace">object (face)</option>
        <option value="object">object (detect)</option>
      </select>
    </label>

    {#if controlState.gravityMode === "anchor" || controlState.gravityMode === "offset"}
      <label class="field">
        <span>Anchor</span>
        <select bind:value={controlState.gravity}>
          <option value="center">center</option>
          <option value="top">north</option>
          <option value="bottom">south</option>
          <option value="right">east</option>
          <option value="left">west</option>
          <option value="top-right">north east</option>
          <option value="top-left">north west</option>
          <option value="bottom-right">south east</option>
          <option value="bottom-left">south west</option>
        </select>
      </label>
    {/if}

    {#if controlState.gravityMode === "focalPoint"}
      <div class="focal-picker-field">
        <span>Focal point</span>
        <ImagePointPicker
          src={`/${source}`}
          markerX={controlState.gravityFocalX}
          markerY={controlState.gravityFocalY}
          ariaLabel={`Set focal point, currently ${controlState.gravityFocalX}, ${controlState.gravityFocalY}`}
          onPick={setFocalPoint}
        />
      </div>

      <RangeNumber
        label="Focal X"
        bind:value={controlState.gravityFocalX}
        min={controlLimits.focalPoint.min}
        max={controlLimits.focalPoint.max}
        step={controlLimits.focalPoint.step}
      />
      <RangeNumber
        label="Focal Y"
        bind:value={controlState.gravityFocalY}
        min={controlLimits.focalPoint.min}
        max={controlLimits.focalPoint.max}
        step={controlLimits.focalPoint.step}
      />
    {/if}

    {#if controlState.gravityMode === "offset"}
      <label class="field">
        <span>Offset X unit</span>
        <select bind:value={controlState.gravityOffsetXUnit}>
          <option value="px">px</option><option value="percent">%</option>
        </select>
      </label>
      <RangeNumber
        label="Offset X"
        bind:value={controlState.gravityOffsetX}
        min={controlLimits.gravityOffset.min}
        max={controlLimits.gravityOffset.max}
        step={controlLimits.gravityOffset.step}
      />
      <RangeNumber
        label="Offset Y"
        bind:value={controlState.gravityOffsetY}
        min={controlLimits.gravityOffset.min}
        max={controlLimits.gravityOffset.max}
        step={controlLimits.gravityOffset.step}
      />
      <label class="field">
        <span>Offset Y unit</span>
        <select bind:value={controlState.gravityOffsetYUnit}>
          <option value="px">px</option><option value="percent">%</option>
        </select>
      </label>
    {/if}

    {#if controlState.gravityMode === "object"}
      <Tabs.Root
        class="obj-submode-tabs"
        value={controlState.objSubMode}
        onValueChange={(v) => {
          controlState.objSubMode = v as "simple" | "weighted";
        }}
      >
        <Tabs.List class="obj-submode-list">
          <Tabs.Trigger class="obj-submode-trigger" value="simple">Simple</Tabs.Trigger>
          <Tabs.Trigger class="obj-submode-trigger" value="weighted">Weighted</Tabs.Trigger>
        </Tabs.List>
      </Tabs.Root>

      <div class="field">
        <span>
          {controlState.gravityMode === "object" && controlState.objSubMode === "weighted"
            ? "Classes + weights"
            : "Classes"}
        </span>
        <Select.Root
          type="multiple"
          value={controlState.objSelectedClasses}
          onValueChange={syncObjClasses}
        >
          <Select.Trigger class="obj-class-trigger">
            {objClassTriggerLabel(controlState.objSelectedClasses)}
            <span class="obj-class-trigger-chevron" aria-hidden="true"></span>
          </Select.Trigger>
          <Select.Content class="obj-class-content" sideOffset={4}>
            <Select.Viewport class="obj-class-viewport">
              {#if controlState.objSubMode === "weighted"}
                <Select.Item class="obj-class-item" value="all" label="all">
                  {#snippet children({ selected })}
                    <span class="obj-class-item-check" aria-hidden="true">
                      {#if selected}✓{/if}
                    </span>
                    all
                  {/snippet}
                </Select.Item>
              {/if}
              {#each fiddleObjClassesForPicker as cls}
                <Select.Item class="obj-class-item" value={cls} label={cls}>
                  {#snippet children({ selected })}
                    <span class="obj-class-item-check" aria-hidden="true">
                      {#if selected}✓{/if}
                    </span>
                    {cls}
                  {/snippet}
                </Select.Item>
              {/each}
            </Select.Viewport>
          </Select.Content>
        </Select.Root>
        {#if controlState.objSelectedClasses.length === 0}
          <p class="field-hint">No classes selected — detects all objects.</p>
        {/if}
      </div>

      {#if controlState.objSubMode === "weighted" && controlState.objSelectedClasses.length > 0}
        {#each controlState.objSelectedClasses as cls (cls)}
          <RangeNumber
            label={cls === "all" ? "Baseline weight (all)" : `${cls} weight`}
            value={controlState.objWeights[cls] ?? 1}
            min={0.1}
            max={10}
            step={0.1}
            inputStep="any"
            onValueChange={(w) => {
              controlState.objWeights = { ...controlState.objWeights, [cls]: w };
            }}
          />
        {/each}
        <p class="field-hint">Weights bias the crop focal point toward a class.</p>
      {/if}
    {/if}
  {/if}
</section>

<section class="tool-section">
  <Collapsible.Root class="collapsible-root" bind:open={scaleOptionsOpen}>
    <Collapsible.Trigger
      class="accordion-heading"
      aria-label={scaleOptionsOpen ? "Collapse scale options" : "Expand scale options"}
    >
      <div>
        <h2>Scale options</h2>
        <p>{resizeExtras || "Off"}</p>
      </div>
      <span class="accordion-chevron" aria-hidden="true"></span>
    </Collapsible.Trigger>

    <Collapsible.Content class="collapsible-content">
      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.zoomEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Zoom</span>
      </label>
      {#if controlState.zoomEnabled}
        <RangeNumber
          label="Zoom"
          bind:value={controlState.zoom}
          min={controlLimits.scale.zoom.min}
          max={controlLimits.scale.zoom.max}
          step={controlLimits.scale.zoom.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.dprEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>DPR</span>
      </label>
      {#if controlState.dprEnabled}
        <RangeNumber
          label="DPR"
          bind:value={controlState.dpr}
          min={controlLimits.scale.dpr.min}
          max={controlLimits.scale.dpr.max}
          step={controlLimits.scale.dpr.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.minWidthEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Minimum width</span>
      </label>
      {#if controlState.minWidthEnabled}
        <RangeNumber
          label="Min width"
          bind:value={controlState.minWidth}
          min={controlLimits.scale.minWidth.min}
          max={controlLimits.scale.minWidth.max}
          step={controlLimits.scale.minWidth.step}
          suffix="px"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.minHeightEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Minimum height</span>
      </label>
      {#if controlState.minHeightEnabled}
        <RangeNumber
          label="Min height"
          bind:value={controlState.minHeight}
          min={controlLimits.scale.minHeight.min}
          max={controlLimits.scale.minHeight.max}
          step={controlLimits.scale.minHeight.step}
          suffix="px"
        />
      {/if}
    </Collapsible.Content>
  </Collapsible.Root>
</section>

<section class="tool-section">
  <Collapsible.Root class="collapsible-root" bind:open={orientationOpen}>
    <Collapsible.Trigger
      class="accordion-heading"
      aria-label={orientationOpen ? "Collapse orientation" : "Expand orientation"}
    >
      <div>
        <h2>Orientation</h2>
        <p>{orientationSummary}</p>
      </div>
      <span class="accordion-chevron" aria-hidden="true"></span>
    </Collapsible.Trigger>

    <Collapsible.Content class="collapsible-content">
      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.autoRotateEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Auto rotate from EXIF</span>
      </label>

      <label class="field">
        <span>Flip</span>
        <select bind:value={controlState.flip}>
          <option value="none">none</option>
          <option value="horizontal">horizontal</option>
          <option value="vertical">vertical</option>
          <option value="both">both</option>
        </select>
      </label>

      <label class="field">
        <span>Rotate</span>
        <select bind:value={controlState.rotate}>
          {#if ![0, 90, 180, 270].includes(controlState.rotate)}
            <option value={controlState.rotate}>{controlState.rotate}°</option>
          {/if}
          <option value={0}>none</option>
          <option value={90}>90°</option>
          <option value={180}>180°</option>
          <option value={270}>270°</option>
        </select>
      </label>
    </Collapsible.Content>
  </Collapsible.Root>
</section>

<section class="tool-section">
  <ToolToggleHeader title="Trim" summary={trimSummary} bind:checked={controlState.trimEnabled} />

  {#if controlState.trimEnabled}
    {#if controlState.trimBackgroundMode === "color"}
      <RangeNumber
        label="Threshold"
        bind:value={controlState.trimThreshold}
        min={0}
        max={100}
        step={1}
      />
    {/if}

    <label class="field">
      <span>Background</span>
      <select bind:value={controlState.trimBackgroundMode}>
        <option value="auto">auto (smart detect)</option>
        <option value="color">color</option>
      </select>
    </label>

    {#if controlState.trimBackgroundMode === "color"}
      <label class="field trim-color-field">
        <span>Color</span>
        <input class="color-input" type="color" bind:value={controlState.trimColor} />
      </label>
    {/if}

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={controlState.trimEqualHor}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Equal horizontal</span>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={controlState.trimEqualVer}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Equal vertical</span>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Aspect canvas"
    summary={aspectCanvasSummary}
    bind:checked={controlState.aspectCanvasEnabled}
  />

  {#if controlState.aspectCanvasEnabled}
    <label class="field">
      <span>Gravity</span>
      <select bind:value={controlState.aspectCanvasGravity}>
        <option value="center">center</option>
        <option value="top">north</option>
        <option value="bottom">south</option>
        <option value="right">east</option>
        <option value="left">west</option>
        <option value="top-right">north east</option>
        <option value="top-left">north west</option>
        <option value="bottom-right">south east</option>
        <option value="bottom-left">south west</option>
      </select>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Padding"
    summary={paddingSummary}
    bind:checked={controlState.paddingEnabled}
  />

  {#if controlState.paddingEnabled}
    <RangeNumber
      label="Top"
      bind:value={controlState.paddingTop}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Right"
      bind:value={controlState.paddingRight}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Bottom"
      bind:value={controlState.paddingBottom}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Left"
      bind:value={controlState.paddingLeft}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Background"
    summary={backgroundSummary}
    bind:checked={controlState.backgroundEnabled}
  />

  {#if controlState.backgroundEnabled}
    <div class="background-controls">
      <label class="field background-color-field">
        <span>Color</span>
        <input class="color-input" type="color" bind:value={controlState.backgroundColor} />
      </label>

      <div class="background-opacity-field">
        <RangeNumber
          label="Opacity"
          bind:value={controlState.backgroundAlpha}
          min={controlLimits.alpha.min}
          max={controlLimits.alpha.max}
          step={controlLimits.alpha.step}
          inputStep="any"
        />
      </div>
    </div>
  {/if}
</section>

<section class="tool-section">
  <Collapsible.Root class="collapsible-root" bind:open={effectsOpen}>
    <Collapsible.Trigger
      class="accordion-heading"
      aria-label={effectsOpen ? "Collapse effects" : "Expand effects"}
    >
      <div>
        <h2>Effects</h2>
        <p>{effectsSummary}</p>
      </div>
      <span class="accordion-chevron" aria-hidden="true"></span>
    </Collapsible.Trigger>

    <Collapsible.Content class="collapsible-content">
      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.blurEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Blur</span>
      </label>
      {#if controlState.blurEnabled}
        <RangeNumber
          label="Blur sigma"
          bind:value={controlState.blur}
          min={controlLimits.effects.blur.min}
          max={controlLimits.effects.blur.max}
          step={controlLimits.effects.blur.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.sharpenEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Sharpen</span>
      </label>
      {#if controlState.sharpenEnabled}
        <RangeNumber
          label="Sharpen sigma"
          bind:value={controlState.sharpen}
          min={controlLimits.effects.sharpen.min}
          max={controlLimits.effects.sharpen.max}
          step={controlLimits.effects.sharpen.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.pixelateEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Pixelate</span>
      </label>
      {#if controlState.pixelateEnabled}
        <RangeNumber
          label="Block size"
          bind:value={controlState.pixelate}
          min={controlLimits.effects.pixelate.min}
          max={controlLimits.effects.pixelate.max}
          step={controlLimits.effects.pixelate.step}
          suffix="px"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.monochromeEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Monochrome</span>
      </label>
      {#if controlState.monochromeEnabled}
        <div class="monochrome-control-row">
          <RangeNumber
            label="Intensity"
            bind:value={controlState.monochromeIntensity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field monochrome-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={controlState.monochromeColor} />
          </label>
        </div>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.duotoneEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Duotone</span>
      </label>
      {#if controlState.duotoneEnabled}
        <div class="duotone-control-row">
          <RangeNumber
            label="Intensity"
            bind:value={controlState.duotoneIntensity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <div class="duotone-color-controls">
            <label class="field">
              <span>Shadow</span>
              <input class="color-input" type="color" bind:value={controlState.duotoneShadow} />
            </label>
            <label class="field">
              <span>Highlight</span>
              <input class="color-input" type="color" bind:value={controlState.duotoneHighlight} />
            </label>
          </div>
        </div>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.brightnessEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Brightness</span>
      </label>
      {#if controlState.brightnessEnabled}
        <RangeNumber
          label="Brightness"
          bind:value={controlState.brightness}
          min={controlLimits.effects.brightness.min}
          max={controlLimits.effects.brightness.max}
          step={controlLimits.effects.brightness.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.contrastEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Contrast</span>
      </label>
      {#if controlState.contrastEnabled}
        <RangeNumber
          label="Contrast"
          bind:value={controlState.contrast}
          min={controlLimits.effects.contrast.min}
          max={controlLimits.effects.contrast.max}
          step={controlLimits.effects.contrast.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.saturationEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Saturation</span>
      </label>
      {#if controlState.saturationEnabled}
        <RangeNumber
          label="Saturation"
          bind:value={controlState.saturation}
          min={controlLimits.effects.saturation.min}
          max={controlLimits.effects.saturation.max}
          step={controlLimits.effects.saturation.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.colorizeEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Colorize</span>
      </label>
      {#if controlState.colorizeEnabled}
        <div class="colorize-control-row">
          <RangeNumber
            label="Opacity"
            bind:value={controlState.colorizeOpacity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field colorize-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={controlState.colorizeColor} />
          </label>
        </div>
        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={controlState.colorizeKeepAlpha}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Keep alpha</span>
        </label>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={controlState.gradientEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Gradient</span>
      </label>
      {#if controlState.gradientEnabled}
        <div class="gradient-control-row">
          <RangeNumber
            label="Opacity"
            bind:value={controlState.gradientOpacity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field gradient-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={controlState.gradientColor} />
          </label>
        </div>
        <label class="field gradient-direction-field">
          <span>Direction</span>
          <input
            class="text-input"
            type="text"
            bind:value={controlState.gradientDirection}
            placeholder="down / up / left / right or angle"
          />
        </label>
        <RangeNumber
          label="Start"
          bind:value={controlState.gradientStart}
          min={controlLimits.effects.intensity.min}
          max={controlLimits.effects.intensity.max}
          step={controlLimits.effects.intensity.step}
          inputStep="any"
        />
        <RangeNumber
          label="Stop"
          bind:value={controlState.gradientStop}
          min={controlLimits.effects.intensity.min}
          max={controlLimits.effects.intensity.max}
          step={controlLimits.effects.intensity.step}
          inputStep="any"
        />
      {/if}
    </Collapsible.Content>
  </Collapsible.Root>
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Format"
    summary={controlState.formatEnabled ? `format=${controlState.format}` : "Off"}
    bind:checked={controlState.formatEnabled}
  />

  {#if controlState.formatEnabled}
    <label class="field">
      <span>Format</span>
      <select bind:value={controlState.format}>
        <option value="jxl">jxl</option>
        <option value="webp">webp</option>
        <option value="avif">avif</option>
        <option value="jpeg">jpeg</option>
        <option value="png">png</option>
      </select>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Quality"
    summary={controlState.qualityEnabled ? `q=${controlState.quality}` : "Off"}
    bind:checked={controlState.qualityEnabled}
  />

  {#if controlState.qualityEnabled}
    <RangeNumber
      label="Quality"
      bind:value={controlState.quality}
      min={controlLimits.quality.min}
      max={controlLimits.quality.max}
      step={controlLimits.quality.step}
    />
  {/if}
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Autoquality</h2>
      <p>{autoqualitySummary}</p>
    </div>
  </div>

  <label class="field">
    <span>Method</span>
    <select bind:value={controlState.autoqualityMethod}>
      <option value="none">none</option>
      <option value="size">size</option>
      <option value="ssimulacra2">SSIMULACRA2</option>
      <option value="butteraugli">butteraugli</option>
    </select>
  </label>

  {#if controlState.autoqualityMethod === "size"}
    <RangeNumber
      label="Target (bytes)"
      bind:value={controlState.autoqualitySizeTarget}
      min={controlLimits.autoquality.sizeTarget.min}
      max={controlLimits.autoquality.sizeTarget.max}
      step={controlLimits.autoquality.sizeTarget.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={controlState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={controlState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
  {/if}

  {#if controlState.autoqualityMethod === "ssimulacra2"}
    <RangeNumber
      label="Target (SSIMULACRA2)"
      bind:value={controlState.autoqualitySsim2Target}
      min={controlLimits.autoquality.ssim2Target.min}
      max={controlLimits.autoquality.ssim2Target.max}
      step={controlLimits.autoquality.ssim2Target.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={controlState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={controlState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Allowed error"
      bind:value={controlState.autoqualityAllowedError}
      min={controlLimits.autoquality.allowedError.min}
      max={controlLimits.autoquality.allowedError.max}
      step={controlLimits.autoquality.allowedError.step}
    />
  {/if}

  {#if controlState.autoqualityMethod === "butteraugli"}
    <RangeNumber
      label="Target (butteraugli distance, lower=better)"
      bind:value={controlState.autoqualityButteraugliTarget}
      min={controlLimits.autoquality.butteraugliTarget.min}
      max={controlLimits.autoquality.butteraugliTarget.max}
      step={controlLimits.autoquality.butteraugliTarget.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={controlState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={controlState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Allowed error"
      bind:value={controlState.autoqualityAllowedError}
      min={controlLimits.autoquality.allowedError.min}
      max={controlLimits.autoquality.allowedError.max}
      step={controlLimits.autoquality.allowedError.step}
    />
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Max bytes"
    summary={maxBytesSummary}
    bind:checked={controlState.maxBytesEnabled}
  />

  {#if controlState.maxBytesEnabled}
    <RangeNumber
      label="Max bytes"
      bind:value={controlState.maxBytes}
      min={controlLimits.maxBytes.min}
      max={controlLimits.maxBytes.max}
      step={controlLimits.maxBytes.step}
    />
  {/if}
</section>

<section class="tool-section">
  <Collapsible.Root class="collapsible-root" bind:open={encoderOptionsOpen}>
    <Collapsible.Trigger
      class="accordion-heading"
      aria-label={encoderOptionsOpen ? "Collapse encoder options" : "Expand encoder options"}
    >
      <div>
        <h2>Encoder options</h2>
        <p>{encoderOptionsSummary}</p>
      </div>
      <span class="accordion-chevron" aria-hidden="true"></span>
    </Collapsible.Trigger>

    <Collapsible.Content class="collapsible-content">
      <h3 class="encoder-format-heading">JPEG</h3>

      <label class="field">
        <span>Progressive</span>
        <select
          value={triBoolValue(controlState.jpegOptions.progressive)}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              progressive: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>No subsample</span>
        <select
          value={triBoolValue(controlState.jpegOptions.no_subsample)}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              no_subsample: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Trellis quant</span>
        <select
          value={triBoolValue(controlState.jpegOptions.trellis_quant)}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              trellis_quant: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Overshoot deringing</span>
        <select
          value={triBoolValue(controlState.jpegOptions.overshoot_deringing)}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              overshoot_deringing: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Optimize scans</span>
        <select
          value={triBoolValue(controlState.jpegOptions.optimize_scans)}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              optimize_scans: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Quant table (0–8)</span>
        <input
          class="text-input"
          type="number"
          min="0"
          max="8"
          step="1"
          value={controlState.jpegOptions.quant_table ?? ""}
          onchange={(e) => {
            controlState.jpegOptions = {
              ...controlState.jpegOptions,
              quant_table: fromIntInput(e.currentTarget.value, 0, 8),
            };
          }}
        />
      </label>

      <h3 class="encoder-format-heading">PNG</h3>

      <label class="field">
        <span>Interlaced</span>
        <select
          value={triBoolValue(controlState.pngOptions.interlaced)}
          onchange={(e) => {
            controlState.pngOptions = {
              ...controlState.pngOptions,
              interlaced: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Quantize</span>
        <select
          value={triBoolValue(controlState.pngOptions.quantize)}
          onchange={(e) => {
            controlState.pngOptions = {
              ...controlState.pngOptions,
              quantize: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Bit depth</span>
        <select
          value={controlState.pngOptions.bitdepth ?? ""}
          onchange={(e) => {
            controlState.pngOptions = {
              ...controlState.pngOptions,
              bitdepth: e.currentTarget.value === "" ? undefined : Number(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          {#each [1, 2, 4, 8, 16] as depth}<option value={depth}>{depth}</option>{/each}
        </select>
      </label>

      <h3 class="encoder-format-heading">WebP</h3>

      <label class="field">
        <span>Compression</span>
        <select
          value={selectValue(controlState.webpOptions.compression)}
          onchange={(e) => {
            controlState.webpOptions = {
              ...controlState.webpOptions,
              compression: fromSelectValue(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="lossy">lossy</option>
          <option value="near_lossless">near_lossless</option>
          <option value="lossless">lossless</option>
        </select>
      </label>

      <label class="field">
        <span>Smart subsample</span>
        <select
          value={triBoolValue(controlState.webpOptions.smart_subsample)}
          onchange={(e) => {
            controlState.webpOptions = {
              ...controlState.webpOptions,
              smart_subsample: fromTriBool(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>

      <label class="field">
        <span>Preset</span>
        <select
          value={selectValue(controlState.webpOptions.preset)}
          onchange={(e) => {
            controlState.webpOptions = {
              ...controlState.webpOptions,
              preset: fromSelectValue(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="default">default</option>
          <option value="photo">photo</option>
          <option value="picture">picture</option>
          <option value="drawing">drawing</option>
          <option value="icon">icon</option>
          <option value="text">text</option>
        </select>
      </label>

      <h3 class="encoder-format-heading">AVIF</h3>

      <label class="field">
        <span>Subsample</span>
        <select
          value={selectValue(controlState.avifOptions.subsample)}
          onchange={(e) => {
            controlState.avifOptions = {
              ...controlState.avifOptions,
              subsample: fromSelectValue(e.currentTarget.value),
            };
          }}
        >
          <option value="">&lt;unset&gt;</option>
          <option value="auto">auto</option>
          <option value="on">on</option>
          <option value="off">off</option>
        </select>
      </label>
    </Collapsible.Content>
  </Collapsible.Root>
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Metadata &amp; color</h2>
      <p>{metadataSummary}</p>
    </div>
  </div>

  <label class="switch-field">
    <Switch.Root
      class="switch-root"
      checked={controlState.stripMetadata}
      onCheckedChange={updateStripMetadata}
    >
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Strip metadata</span>
  </label>

  <label class="switch-field">
    <Switch.Root
      class="switch-root"
      bind:checked={controlState.keepCopyright}
      disabled={!controlState.stripMetadata}
    >
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span class:muted-label={!controlState.stripMetadata}>Keep copyright</span>
  </label>

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={controlState.stripColorProfile}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Strip color profile</span>
  </label>

  <label class="field">
    <span>Color profile</span>
    <select bind:value={controlState.colorProfile}>
      <option value="none">none</option>
      <option value="srgb">srgb</option>
      <option value="display-p3">display-p3</option>
      <option value="adobe-rgb">adobe-rgb</option>
    </select>
  </label>

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={controlState.preserveHdr}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Preserve HDR</span>
  </label>
</section>

<style>
  .focal-picker-field {
    display: flex;
    flex-direction: column;
    gap: 8px;
    color: var(--text-label);
    font-size: 13px;
    line-height: 18px;
  }

  .field-hint {
    margin: 0;
    color: var(--text-muted);
    font-size: 12px;
    line-height: 16px;
  }

  .field > span {
    display: flex;
    justify-content: space-between;
    gap: 12px;
  }

  .background-controls {
    display: flex;
    align-items: start;
    gap: 14px;
  }

  .background-color-field {
    flex: 0 0 58px;
  }

  .background-opacity-field {
    min-width: 0;
    flex: 1;
  }

  .monochrome-control-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    align-items: start;
    gap: 14px;
  }

  .monochrome-color-field {
    width: 58px;
  }

  .duotone-control-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    align-items: start;
    gap: 14px;
  }

  .duotone-color-controls {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 10px;
  }

  .colorize-control-row,
  .gradient-control-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    align-items: start;
    gap: 14px;
  }

  .colorize-color-field,
  .gradient-color-field {
    width: 58px;
  }

  .text-input {
    min-height: 38px;
    width: 100%;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    color: var(--text-primary);
    padding: 0 12px;
  }

  /* Segmented control (Simple / Weighted sub-mode tabs) */
  :global(.obj-submode-tabs) {
    display: flex;
    flex-direction: column;
  }

  :global(.obj-submode-list) {
    display: inline-flex;
    height: 32px;
    padding: 3px;
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-control-track);
    gap: 2px;
  }

  :global(.obj-submode-trigger) {
    flex: 1;
    height: 100%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 5px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    font: inherit;
    font-size: 13px;
    font-weight: 500;
    line-height: 1;
    padding-inline: 10px;
    transition:
      background-color 120ms ease-out,
      color 120ms ease-out;
  }

  :global(.obj-submode-trigger[data-state="active"]) {
    background: var(--surface-control);
    color: var(--text-heading);
    box-shadow: 0 0 0 1px var(--border-subtle);
  }

  :global(.obj-submode-trigger:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  /* Class multi-select dropdown */
  :global(.obj-class-trigger) {
    min-width: 0;
    width: 100%;
    height: 38px;
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

    &:focus-visible {
      outline: 2px solid var(--focus-ring);
      outline-offset: 2px;
    }
  }

  .obj-class-trigger-chevron {
    width: 5px;
    height: 5px;
    flex-shrink: 0;
    border-inline-end: 2px solid var(--text-muted);
    border-block-end: 2px solid var(--text-muted);
    transform: rotate(45deg) translate(-1px, -1px);
    margin-inline-end: 4px;
  }

  :global(.obj-class-trigger[data-state="open"]) .obj-class-trigger-chevron {
    transform: rotate(-135deg) translate(-1px, -1px);
  }

  :global(.obj-class-content) {
    min-width: var(--bits-select-anchor-width, 180px);
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-sidebar);
    box-shadow: var(--image-shadow);
    overflow: hidden;
    z-index: 50;
  }

  :global(.obj-class-viewport) {
    padding: 4px;
  }

  :global(.obj-class-item) {
    height: 32px;
    display: flex;
    align-items: center;
    gap: 8px;
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

    &:hover,
    &[data-highlighted] {
      background: color-mix(in srgb, var(--accent) 12%, var(--surface-control));
      color: var(--text-heading);
    }

    &[data-selected] {
      color: var(--text-heading);
      font-weight: 500;
    }
  }

  .obj-class-item-check {
    width: 14px;
    flex-shrink: 0;
    color: var(--accent);
    font-size: 12px;
    line-height: 1;
  }

  .color-input {
    width: 100%;
    height: 38px;
    border: 1px solid var(--border-strong);
    border-radius: 7px;
    background: var(--surface-control);
    padding: 4px;
    cursor: pointer;
  }

  .muted-label {
    color: var(--text-muted);
  }

  .encoder-format-heading {
    margin: 6px 0 0;
    color: var(--text-heading);
    font-size: 12px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
</style>

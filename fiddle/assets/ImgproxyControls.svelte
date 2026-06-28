<script lang="ts">
  import { Collapsible, Select, Switch, Tabs } from "bits-ui";
  import CropDimensionControl from "./CropDimensionControl.svelte";
  import ImagePointPicker from "./ImagePointPicker.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import ResizeDimensionControl from "./ResizeDimensionControl.svelte";
  import ToolToggleHeader from "./ToolToggleHeader.svelte";
  import { fiddleObjClasses, expandedToolboxesForState } from "./fiddle-url-state";
  import {
    autoqualityOptionSegment,
    avifOptionsSegment,
    controlLimits,
    cropOptionSegment,
    cropPixelLimit,
    gravitySegment,
    jpegOptionsSegment,
    pngOptionsSegment,
    resizeOptionSegment,
    resetCropPixelsToSource,
    trimOptionSegment,
    webpOptionsSegment,
    type FiddleState,
    type SourceImage,
  } from "./processing-path";

  type Props = {
    fiddleState: FiddleState;
    source: SourceImage;
  };

  let { fiddleState = $bindable(), source }: Props = $props();

  let orientationOpen = $state(true);
  let scaleOptionsOpen = $state(true);
  let effectsOpen = $state(true);
  let encoderOptionsOpen = $state(true);

  const fiddleObjClassesForPicker = fiddleObjClasses as readonly string[];

  const cropWidthLimit = $derived(cropPixelLimit(source, "width"));
  const cropHeightLimit = $derived(cropPixelLimit(source, "height"));

  $effect(() => {
    const open = expandedToolboxesForState(fiddleState);
    if (open.orientationOpen) orientationOpen = true;
    if (open.scaleOptionsOpen) scaleOptionsOpen = true;
    if (open.effectsOpen) effectsOpen = true;
  });

  const orientationSummary = $derived(
    [
      fiddleState.autoRotateEnabled ? "ar:1" : null,
      flipSegment(fiddleState.flip),
      fiddleState.rotate === 0 ? null : `rot:${fiddleState.rotate}`,
    ]
      .filter(Boolean)
      .join("/") || "Off",
  );
  const trimSummary = $derived(
    fiddleState.trimEnabled ? (trimOptionSegment(fiddleState) ?? "Off") : "Off",
  );
  const resizeSummary = $derived(
    fiddleState.resizeEnabled ? (resizeOptionSegment(fiddleState) ?? "Off") : "Off",
  );
  const aspectCanvasSummary = $derived(
    fiddleState.aspectCanvasEnabled
      ? fiddleState.aspectCanvasGravity === "ce"
        ? "exar:1"
        : `exar:1:${fiddleState.aspectCanvasGravity}`
      : "Off",
  );
  const paddingSummary = $derived(
    fiddleState.paddingEnabled
      ? `pd:${fiddleState.paddingTop}:${fiddleState.paddingRight}:${fiddleState.paddingBottom}:${fiddleState.paddingLeft}`
      : "Off",
  );
  const backgroundSummary = $derived(
    fiddleState.backgroundEnabled
      ? `bg:${fiddleState.backgroundColor.replace(/^#/, "")}${backgroundOpacitySummary(fiddleState.backgroundAlpha)}`
      : "Off",
  );
  const effectsSummary = $derived(effectSegments(fiddleState).join("/") || "Off");
  const metadataSummary = $derived(metadataSegments(fiddleState).join("/") || "On");
  const autoqualitySummary = $derived(autoqualityOptionSegment(fiddleState) ?? "Off");
  const encoderOptionsSummary = $derived(
    [
      jpegOptionsSegment(fiddleState),
      pngOptionsSegment(fiddleState),
      webpOptionsSegment(fiddleState),
      avifOptionsSegment(fiddleState),
    ]
      .filter(Boolean)
      .join("/") || "Off",
  );
  const maxBytesSummary = $derived(
    fiddleState.maxBytesEnabled && fiddleState.maxBytes > 0 ? `mb:${fiddleState.maxBytes}` : "Off",
  );
  const cropSummary = $derived(
    fiddleState.cropEnabled ? (cropOptionSegment(fiddleState) ?? "Off") : "Off",
  );
  const cropAspectRatioSummary = $derived(
    fiddleState.cropAspectRatioEnabled
      ? fiddleState.cropAspectRatioEnlarge
        ? `car:${fiddleState.cropAspectRatio}:1`
        : `car:${fiddleState.cropAspectRatio}`
      : "Off",
  );
  const resizeExtras = $derived(
    [
      fiddleState.zoomEnabled ? `z:${fiddleState.zoom}` : null,
      fiddleState.dprEnabled ? `dpr:${fiddleState.dpr}` : null,
      fiddleState.minWidthEnabled ? `mw:${fiddleState.minWidth}` : null,
      fiddleState.minHeightEnabled ? `mh:${fiddleState.minHeight}` : null,
    ]
      .filter(Boolean)
      .join("/"),
  );

  function flipSegment(flip: FiddleState["flip"]): string | null {
    if (flip === "horizontal") {
      return "fl:1";
    }

    if (flip === "vertical") {
      return "fl:0:1";
    }

    if (flip === "both") {
      return "fl";
    }

    return null;
  }

  function backgroundOpacitySummary(alpha: number): string {
    if (alpha >= 1) {
      return "";
    }

    return `/bga:${alpha}`;
  }

  function metadataSegments(currentState: FiddleState): string[] {
    const segs: string[] = [];

    if (!currentState.stripMetadata) {
      segs.push("sm:0");
    } else if (!currentState.keepCopyright) {
      segs.push("kcr:0");
    }

    if (!currentState.stripColorProfile) {
      segs.push("scp:0");
    }

    if (currentState.colorProfile !== "none") {
      segs.push(`cp:${currentState.colorProfile}`);
    }

    if (currentState.preserveHdr) {
      segs.push("ph:1");
    }

    return segs;
  }

  function effectSegments(currentState: FiddleState): string[] {
    return [
      currentState.blurEnabled ? `bl:${currentState.blur}` : null,
      currentState.sharpenEnabled ? `sh:${currentState.sharpen}` : null,
      currentState.pixelateEnabled ? `pix:${currentState.pixelate}` : null,
      currentState.monochromeEnabled
        ? `mc:${currentState.monochromeIntensity}:${currentState.monochromeColor.replace(/^#/, "")}`
        : null,
      currentState.duotoneEnabled
        ? `dt:${currentState.duotoneIntensity}:${currentState.duotoneShadow.replace(
            /^#/,
            "",
          )}:${currentState.duotoneHighlight.replace(/^#/, "")}`
        : null,
      currentState.brightnessEnabled ? `br:${currentState.brightness}` : null,
      currentState.contrastEnabled ? `co:${currentState.contrast}` : null,
      currentState.saturationEnabled ? `sa:${currentState.saturation}` : null,
      currentState.colorizeEnabled
        ? `col:${currentState.colorizeOpacity}:${currentState.colorizeColor.replace(/^#/, "")}:${
            currentState.colorizeKeepAlpha ? 1 : 0
          }`
        : null,
      currentState.gradientEnabled
        ? `gr:${currentState.gradientOpacity}:${currentState.gradientColor.replace(/^#/, "")}:${
            currentState.gradientDirection
          }:${currentState.gradientStart}:${currentState.gradientStop}`
        : null,
    ].filter((segment): segment is string => segment !== null);
  }

  function updateCropEnabled(enabled: boolean): void {
    fiddleState.cropEnabled = enabled;

    if (enabled) {
      fiddleState = resetCropPixelsToSource(fiddleState);
    }
  }

  function updateStripMetadata(checked: boolean): void {
    fiddleState.stripMetadata = checked;

    if (!checked) {
      fiddleState.keepCopyright = false;
    }
  }

  function syncObjClasses(nextClasses: string[]): void {
    // Add default weight for newly selected classes; remove weight for deselected ones.
    const prev = new Set(fiddleState.objSelectedClasses);
    const next = new Set(nextClasses);
    let weights = { ...fiddleState.objWeights };

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

    fiddleState.objSelectedClasses = nextClasses;
    fiddleState.objWeights = weights;
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
    fiddleState.gravityFocalX = nx;
    fiddleState.gravityFocalY = ny;
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

  function fromNumberInput(value: string): number | undefined {
    if (value.trim() === "") {
      return undefined;
    }

    const parsed = Number(value);

    return Number.isFinite(parsed) ? parsed : undefined;
  }
</script>

<section class="tool-section">
  <ToolToggleHeader
    title="Resize"
    summary={resizeSummary}
    bind:checked={fiddleState.resizeEnabled}
  />

  {#if fiddleState.resizeEnabled}
    <ResizeDimensionControl
      label="Width"
      bind:unit={fiddleState.resizeWidthUnit}
      bind:pixels={fiddleState.width}
      maxPixels={controlLimits.resize.width.max}
    />
    <ResizeDimensionControl
      label="Height"
      bind:unit={fiddleState.resizeHeightUnit}
      bind:pixels={fiddleState.height}
      maxPixels={controlLimits.resize.height.max}
    />

    <label class="field">
      <span>Type</span>
      <select bind:value={fiddleState.resizeMode}>
        <option value="fit">fit</option>
        <option value="fill">fill</option>
        <option value="fill-down">fill-down</option>
        <option value="force">force</option>
        <option value="auto">auto</option>
      </select>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={fiddleState.enlarge}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Allow enlargement</span>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={fiddleState.resizeExtendEnabled}>
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
    checked={fiddleState.cropEnabled}
    onCheckedChange={updateCropEnabled}
  />

  {#if fiddleState.cropEnabled}
    <CropDimensionControl
      label="Width"
      bind:unit={fiddleState.cropWidthUnit}
      bind:pixels={fiddleState.cropWidth}
      bind:percent={fiddleState.cropWidthPercent}
      maxPixels={cropWidthLimit.max}
    />
    <CropDimensionControl
      label="Height"
      bind:unit={fiddleState.cropHeightUnit}
      bind:pixels={fiddleState.cropHeight}
      bind:percent={fiddleState.cropHeightPercent}
      maxPixels={cropHeightLimit.max}
    />

    <label class="field">
      <span>Gravity</span>
      <select bind:value={fiddleState.cropGravity}>
        <option value="inherit">&lt;inherit&gt;</option>
        <option value="ce">center</option>
        <option value="no">north</option>
        <option value="so">south</option>
        <option value="ea">east</option>
        <option value="we">west</option>
        <option value="noea">north east</option>
        <option value="nowe">north west</option>
        <option value="soea">south east</option>
        <option value="sowe">south west</option>
        <option value="sm">smart</option>
        <option value="obj:face">object (face)</option>
        <option value="obj">object (all, bare)</option>
        <option value="obj:all">object (all, explicit)</option>
      </select>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Crop aspect ratio"
    summary={cropAspectRatioSummary}
    bind:checked={fiddleState.cropAspectRatioEnabled}
  />

  {#if fiddleState.cropAspectRatioEnabled}
    <RangeNumber
      label="Ratio"
      bind:value={fiddleState.cropAspectRatio}
      min={0}
      max={10}
      step={0.1}
    />
    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={fiddleState.cropAspectRatioEnlarge}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Enlarge</span>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Gravity"
    summary={fiddleState.gravityEnabled ? gravitySegment(fiddleState) : "Off"}
    bind:checked={fiddleState.gravityEnabled}
  />

  {#if fiddleState.gravityEnabled}
    <label class="field">
      <span>Mode</span>
      <select bind:value={fiddleState.gravityMode}>
        <option value="anchor">anchor</option>
        <option value="focalPoint">focal point</option>
        <option value="offset">anchor + offset</option>
        <option value="smart">smart</option>
        <option value="objFace">object (face)</option>
        <option value="object">object (detect)</option>
      </select>
    </label>

    {#if fiddleState.gravityMode === "anchor" || fiddleState.gravityMode === "offset"}
      <label class="field">
        <span>Anchor</span>
        <select bind:value={fiddleState.gravity}>
          <option value="ce">center</option>
          <option value="no">north</option>
          <option value="so">south</option>
          <option value="ea">east</option>
          <option value="we">west</option>
          <option value="noea">north east</option>
          <option value="nowe">north west</option>
          <option value="soea">south east</option>
          <option value="sowe">south west</option>
        </select>
      </label>
    {/if}

    {#if fiddleState.gravityMode === "focalPoint"}
      <div class="focal-picker-field">
        <span>Focal point</span>
        <ImagePointPicker
          src={`/${source}`}
          markerX={fiddleState.gravityFocalX}
          markerY={fiddleState.gravityFocalY}
          ariaLabel={`Set focal point, currently ${fiddleState.gravityFocalX}, ${fiddleState.gravityFocalY}`}
          onPick={setFocalPoint}
        />
      </div>

      <RangeNumber
        label="Focal X"
        bind:value={fiddleState.gravityFocalX}
        min={controlLimits.focalPoint.min}
        max={controlLimits.focalPoint.max}
        step={controlLimits.focalPoint.step}
      />
      <RangeNumber
        label="Focal Y"
        bind:value={fiddleState.gravityFocalY}
        min={controlLimits.focalPoint.min}
        max={controlLimits.focalPoint.max}
        step={controlLimits.focalPoint.step}
      />
    {/if}

    {#if fiddleState.gravityMode === "offset"}
      <RangeNumber
        label="Offset X"
        bind:value={fiddleState.gravityOffsetX}
        min={controlLimits.gravityOffset.min}
        max={controlLimits.gravityOffset.max}
        step={controlLimits.gravityOffset.step}
      />
      <RangeNumber
        label="Offset Y"
        bind:value={fiddleState.gravityOffsetY}
        min={controlLimits.gravityOffset.min}
        max={controlLimits.gravityOffset.max}
        step={controlLimits.gravityOffset.step}
      />
    {/if}

    {#if fiddleState.gravityMode === "object"}
      <!-- Object-gravity mode: filter detection to named classes + optional weights.
           Simple = g:obj:<classes> (filters but no weight bias).
           Weighted = g:objw:<class>:<weight>... (filters AND weights).
           Empty selection = bare g:obj (all objects, no filter). -->
      <Tabs.Root
        class="obj-submode-tabs"
        value={fiddleState.objSubMode}
        onValueChange={(v) => {
          fiddleState.objSubMode = v as "simple" | "weighted";
        }}
      >
        <Tabs.List class="obj-submode-list">
          <Tabs.Trigger class="obj-submode-trigger" value="simple">Simple</Tabs.Trigger>
          <Tabs.Trigger class="obj-submode-trigger" value="weighted">Weighted</Tabs.Trigger>
        </Tabs.List>
      </Tabs.Root>

      <div class="field">
        <span>
          {fiddleState.gravityMode === "object" && fiddleState.objSubMode === "weighted"
            ? "Classes + weights"
            : "Classes"}
        </span>
        <!-- Multi-select dropdown: choose individual detection classes.
             Empty selection = all objects (bare g:obj).
             In weighted mode "all" is offered as a baseline option. -->
        <Select.Root
          type="multiple"
          value={fiddleState.objSelectedClasses}
          onValueChange={syncObjClasses}
        >
          <Select.Trigger class="obj-class-trigger">
            {objClassTriggerLabel(fiddleState.objSelectedClasses)}
            <span class="obj-class-trigger-chevron" aria-hidden="true"></span>
          </Select.Trigger>
          <Select.Content class="obj-class-content" sideOffset={4}>
            <Select.Viewport class="obj-class-viewport">
              {#if fiddleState.objSubMode === "weighted"}
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
        {#if fiddleState.objSelectedClasses.length === 0}
          <p class="field-hint">No classes selected — detects all objects.</p>
        {/if}
      </div>

      {#if fiddleState.objSubMode === "weighted" && fiddleState.objSelectedClasses.length > 0}
        {#each fiddleState.objSelectedClasses as cls (cls)}
          <RangeNumber
            label={cls === "all" ? "Baseline weight (all)" : `${cls} weight`}
            value={fiddleState.objWeights[cls] ?? 1}
            min={0.1}
            max={10}
            step={0.1}
            inputStep="any"
            onValueChange={(w) => {
              fiddleState.objWeights = { ...fiddleState.objWeights, [cls]: w };
            }}
          />
        {/each}
        <p class="field-hint">
          Weights bias the crop focal point toward a class. Non-uniform weights emit
          <code>g:objw</code>; uniform weights use the compact <code>g:obj</code> form.
        </p>
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
        <Switch.Root class="switch-root" bind:checked={fiddleState.zoomEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Zoom</span>
      </label>
      {#if fiddleState.zoomEnabled}
        <RangeNumber
          label="Zoom"
          bind:value={fiddleState.zoom}
          min={controlLimits.scale.zoom.min}
          max={controlLimits.scale.zoom.max}
          step={controlLimits.scale.zoom.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.dprEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>DPR</span>
      </label>
      {#if fiddleState.dprEnabled}
        <RangeNumber
          label="DPR"
          bind:value={fiddleState.dpr}
          min={controlLimits.scale.dpr.min}
          max={controlLimits.scale.dpr.max}
          step={controlLimits.scale.dpr.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.minWidthEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Minimum width</span>
      </label>
      {#if fiddleState.minWidthEnabled}
        <RangeNumber
          label="Min width"
          bind:value={fiddleState.minWidth}
          min={controlLimits.scale.minWidth.min}
          max={controlLimits.scale.minWidth.max}
          step={controlLimits.scale.minWidth.step}
          suffix="px"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.minHeightEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Minimum height</span>
      </label>
      {#if fiddleState.minHeightEnabled}
        <RangeNumber
          label="Min height"
          bind:value={fiddleState.minHeight}
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
        <Switch.Root class="switch-root" bind:checked={fiddleState.autoRotateEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Auto rotate from EXIF</span>
      </label>

      <label class="field">
        <span>Flip</span>
        <select bind:value={fiddleState.flip}>
          <option value="none">none</option>
          <option value="horizontal">horizontal</option>
          <option value="vertical">vertical</option>
          <option value="both">both</option>
        </select>
      </label>

      <label class="field">
        <span>Rotate</span>
        <select bind:value={fiddleState.rotate}>
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
  <ToolToggleHeader title="Trim" summary={trimSummary} bind:checked={fiddleState.trimEnabled} />

  {#if fiddleState.trimEnabled}
    <RangeNumber
      label="Threshold"
      bind:value={fiddleState.trimThreshold}
      min={0}
      max={100}
      step={1}
    />

    <label class="field">
      <span>Background</span>
      <select bind:value={fiddleState.trimBackgroundMode}>
        <option value="auto">auto (smart detect)</option>
        <option value="color">color</option>
      </select>
    </label>

    {#if fiddleState.trimBackgroundMode === "color"}
      <label class="field trim-color-field">
        <span>Color</span>
        <input class="color-input" type="color" bind:value={fiddleState.trimColor} />
      </label>
    {/if}

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={fiddleState.trimEqualHor}>
        <Switch.Thumb class="switch-thumb" />
      </Switch.Root>
      <span>Equal horizontal</span>
    </label>

    <label class="switch-field">
      <Switch.Root class="switch-root" bind:checked={fiddleState.trimEqualVer}>
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
    bind:checked={fiddleState.aspectCanvasEnabled}
  />

  {#if fiddleState.aspectCanvasEnabled}
    <label class="field">
      <span>Gravity</span>
      <select bind:value={fiddleState.aspectCanvasGravity}>
        <option value="ce">center</option>
        <option value="no">north</option>
        <option value="so">south</option>
        <option value="ea">east</option>
        <option value="we">west</option>
        <option value="noea">north east</option>
        <option value="nowe">north west</option>
        <option value="soea">south east</option>
        <option value="sowe">south west</option>
      </select>
    </label>
  {/if}
</section>

<section class="tool-section">
  <ToolToggleHeader
    title="Padding"
    summary={paddingSummary}
    bind:checked={fiddleState.paddingEnabled}
  />

  {#if fiddleState.paddingEnabled}
    <RangeNumber
      label="Top"
      bind:value={fiddleState.paddingTop}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Right"
      bind:value={fiddleState.paddingRight}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Bottom"
      bind:value={fiddleState.paddingBottom}
      min={controlLimits.padding.min}
      max={controlLimits.padding.max}
      step={controlLimits.padding.step}
      suffix="px"
    />
    <RangeNumber
      label="Left"
      bind:value={fiddleState.paddingLeft}
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
    bind:checked={fiddleState.backgroundEnabled}
  />

  {#if fiddleState.backgroundEnabled}
    <div class="background-controls">
      <label class="field background-color-field">
        <span>Color</span>
        <input class="color-input" type="color" bind:value={fiddleState.backgroundColor} />
      </label>

      <div class="background-opacity-field">
        <RangeNumber
          label="Opacity"
          bind:value={fiddleState.backgroundAlpha}
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
        <Switch.Root class="switch-root" bind:checked={fiddleState.blurEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Blur</span>
      </label>
      {#if fiddleState.blurEnabled}
        <RangeNumber
          label="Blur sigma"
          bind:value={fiddleState.blur}
          min={controlLimits.effects.blur.min}
          max={controlLimits.effects.blur.max}
          step={controlLimits.effects.blur.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.sharpenEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Sharpen</span>
      </label>
      {#if fiddleState.sharpenEnabled}
        <RangeNumber
          label="Sharpen sigma"
          bind:value={fiddleState.sharpen}
          min={controlLimits.effects.sharpen.min}
          max={controlLimits.effects.sharpen.max}
          step={controlLimits.effects.sharpen.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.pixelateEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Pixelate</span>
      </label>
      {#if fiddleState.pixelateEnabled}
        <RangeNumber
          label="Block size"
          bind:value={fiddleState.pixelate}
          min={controlLimits.effects.pixelate.min}
          max={controlLimits.effects.pixelate.max}
          step={controlLimits.effects.pixelate.step}
          suffix="px"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.monochromeEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Monochrome</span>
      </label>
      {#if fiddleState.monochromeEnabled}
        <div class="monochrome-control-row">
          <RangeNumber
            label="Intensity"
            bind:value={fiddleState.monochromeIntensity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field monochrome-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={fiddleState.monochromeColor} />
          </label>
        </div>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.duotoneEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Duotone</span>
      </label>
      {#if fiddleState.duotoneEnabled}
        <div class="duotone-control-row">
          <RangeNumber
            label="Intensity"
            bind:value={fiddleState.duotoneIntensity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <div class="duotone-color-controls">
            <label class="field">
              <span>Shadow</span>
              <input class="color-input" type="color" bind:value={fiddleState.duotoneShadow} />
            </label>
            <label class="field">
              <span>Highlight</span>
              <input class="color-input" type="color" bind:value={fiddleState.duotoneHighlight} />
            </label>
          </div>
        </div>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.brightnessEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Brightness</span>
      </label>
      {#if fiddleState.brightnessEnabled}
        <RangeNumber
          label="Brightness"
          bind:value={fiddleState.brightness}
          min={controlLimits.effects.brightness.min}
          max={controlLimits.effects.brightness.max}
          step={controlLimits.effects.brightness.step}
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.contrastEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Contrast</span>
      </label>
      {#if fiddleState.contrastEnabled}
        <RangeNumber
          label="Contrast"
          bind:value={fiddleState.contrast}
          min={controlLimits.effects.contrast.min}
          max={controlLimits.effects.contrast.max}
          step={controlLimits.effects.contrast.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.saturationEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Saturation</span>
      </label>
      {#if fiddleState.saturationEnabled}
        <RangeNumber
          label="Saturation"
          bind:value={fiddleState.saturation}
          min={controlLimits.effects.saturation.min}
          max={controlLimits.effects.saturation.max}
          step={controlLimits.effects.saturation.step}
          inputStep="any"
        />
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.colorizeEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Colorize</span>
      </label>
      {#if fiddleState.colorizeEnabled}
        <div class="colorize-control-row">
          <RangeNumber
            label="Opacity"
            bind:value={fiddleState.colorizeOpacity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field colorize-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={fiddleState.colorizeColor} />
          </label>
        </div>
        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={fiddleState.colorizeKeepAlpha}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Keep alpha</span>
        </label>
      {/if}

      <label class="switch-field">
        <Switch.Root class="switch-root" bind:checked={fiddleState.gradientEnabled}>
          <Switch.Thumb class="switch-thumb" />
        </Switch.Root>
        <span>Gradient</span>
      </label>
      {#if fiddleState.gradientEnabled}
        <div class="gradient-control-row">
          <RangeNumber
            label="Opacity"
            bind:value={fiddleState.gradientOpacity}
            min={controlLimits.effects.intensity.min}
            max={controlLimits.effects.intensity.max}
            step={controlLimits.effects.intensity.step}
            inputStep="any"
          />
          <label class="field gradient-color-field">
            <span>Color</span>
            <input class="color-input" type="color" bind:value={fiddleState.gradientColor} />
          </label>
        </div>
        <label class="field gradient-direction-field">
          <span>Direction</span>
          <input
            class="text-input"
            type="text"
            bind:value={fiddleState.gradientDirection}
            placeholder="down / up / left / right or angle"
          />
        </label>
        <RangeNumber
          label="Start"
          bind:value={fiddleState.gradientStart}
          min={controlLimits.effects.intensity.min}
          max={controlLimits.effects.intensity.max}
          step={controlLimits.effects.intensity.step}
          inputStep="any"
        />
        <RangeNumber
          label="Stop"
          bind:value={fiddleState.gradientStop}
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
    summary={fiddleState.formatEnabled ? `f:${fiddleState.format}` : "Off"}
    bind:checked={fiddleState.formatEnabled}
  />

  {#if fiddleState.formatEnabled}
    <label class="field">
      <span>Format</span>
      <select bind:value={fiddleState.format}>
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
    summary={fiddleState.qualityEnabled ? `q:${fiddleState.quality}` : "Off"}
    bind:checked={fiddleState.qualityEnabled}
  />

  {#if fiddleState.qualityEnabled}
    <RangeNumber
      label="Quality"
      bind:value={fiddleState.quality}
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
    <select bind:value={fiddleState.autoqualityMethod}>
      <option value="none">none</option>
      <option value="size">size</option>
      <option value="ssim2">ssim2</option>
      <option value="butteraugli">butteraugli</option>
    </select>
  </label>

  {#if fiddleState.autoqualityMethod === "size"}
    <RangeNumber
      label="Target (bytes)"
      bind:value={fiddleState.autoqualitySizeTarget}
      min={controlLimits.autoquality.sizeTarget.min}
      max={controlLimits.autoquality.sizeTarget.max}
      step={controlLimits.autoquality.sizeTarget.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={fiddleState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={fiddleState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
  {/if}

  {#if fiddleState.autoqualityMethod === "ssim2"}
    <RangeNumber
      label="Target (SSIMULACRA2)"
      bind:value={fiddleState.autoqualitySsim2Target}
      min={controlLimits.autoquality.ssim2Target.min}
      max={controlLimits.autoquality.ssim2Target.max}
      step={controlLimits.autoquality.ssim2Target.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={fiddleState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={fiddleState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Allowed error"
      bind:value={fiddleState.autoqualityAllowedError}
      min={controlLimits.autoquality.allowedError.min}
      max={controlLimits.autoquality.allowedError.max}
      step={controlLimits.autoquality.allowedError.step}
    />
  {/if}

  {#if fiddleState.autoqualityMethod === "butteraugli"}
    <RangeNumber
      label="Target (butteraugli distance, lower=better)"
      bind:value={fiddleState.autoqualityButteraugliTarget}
      min={controlLimits.autoquality.butteraugliTarget.min}
      max={controlLimits.autoquality.butteraugliTarget.max}
      step={controlLimits.autoquality.butteraugliTarget.step}
    />
    <RangeNumber
      label="Min quality"
      bind:value={fiddleState.autoqualityMinQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Max quality"
      bind:value={fiddleState.autoqualityMaxQuality}
      min={controlLimits.autoquality.quality.min}
      max={controlLimits.autoquality.quality.max}
      step={controlLimits.autoquality.quality.step}
    />
    <RangeNumber
      label="Allowed error"
      bind:value={fiddleState.autoqualityAllowedError}
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
    bind:checked={fiddleState.maxBytesEnabled}
  />

  {#if fiddleState.maxBytesEnabled}
    <RangeNumber
      label="Max bytes"
      bind:value={fiddleState.maxBytes}
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
      <!-- jpgo:%progressive:%no_subsample:%trellis_quant:%overshoot_deringing:%optimize_scans:%quant_table -->
      <h3 class="encoder-format-heading">JPEG (jpgo)</h3>

      <label class="field">
        <span>Progressive</span>
        <select
          value={triBoolValue(fiddleState.jpegOptions.progressive)}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
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
          value={triBoolValue(fiddleState.jpegOptions.no_subsample)}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
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
          value={triBoolValue(fiddleState.jpegOptions.trellis_quant)}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
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
          value={triBoolValue(fiddleState.jpegOptions.overshoot_deringing)}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
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
          value={triBoolValue(fiddleState.jpegOptions.optimize_scans)}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
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
          value={fiddleState.jpegOptions.quant_table ?? ""}
          onchange={(e) => {
            fiddleState.jpegOptions = {
              ...fiddleState.jpegOptions,
              quant_table: fromNumberInput(e.currentTarget.value),
            };
          }}
        />
      </label>

      <!-- pngo:%interlaced:%quantize:%quantization_colors -->
      <h3 class="encoder-format-heading">PNG (pngo)</h3>

      <label class="field">
        <span>Interlaced</span>
        <select
          value={triBoolValue(fiddleState.pngOptions.interlaced)}
          onchange={(e) => {
            fiddleState.pngOptions = {
              ...fiddleState.pngOptions,
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
          value={triBoolValue(fiddleState.pngOptions.quantize)}
          onchange={(e) => {
            fiddleState.pngOptions = {
              ...fiddleState.pngOptions,
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
        <span>Quantization colors (2–256)</span>
        <input
          class="text-input"
          type="number"
          min="2"
          max="256"
          step="1"
          value={fiddleState.pngOptions.quantization_colors ?? ""}
          onchange={(e) => {
            fiddleState.pngOptions = {
              ...fiddleState.pngOptions,
              quantization_colors: fromNumberInput(e.currentTarget.value),
            };
          }}
        />
      </label>

      <!-- webpo:%compression:%smart_subsample:%preset -->
      <h3 class="encoder-format-heading">WebP (webpo)</h3>

      <label class="field">
        <span>Compression</span>
        <select
          value={selectValue(fiddleState.webpOptions.compression)}
          onchange={(e) => {
            fiddleState.webpOptions = {
              ...fiddleState.webpOptions,
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
          value={triBoolValue(fiddleState.webpOptions.smart_subsample)}
          onchange={(e) => {
            fiddleState.webpOptions = {
              ...fiddleState.webpOptions,
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
          value={selectValue(fiddleState.webpOptions.preset)}
          onchange={(e) => {
            fiddleState.webpOptions = {
              ...fiddleState.webpOptions,
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

      <!-- avifo:%subsample -->
      <h3 class="encoder-format-heading">AVIF (avifo)</h3>

      <label class="field">
        <span>Subsample</span>
        <select
          value={selectValue(fiddleState.avifOptions.subsample)}
          onchange={(e) => {
            fiddleState.avifOptions = {
              ...fiddleState.avifOptions,
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
      checked={fiddleState.stripMetadata}
      onCheckedChange={updateStripMetadata}
    >
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Strip metadata (sm)</span>
  </label>

  <label class="switch-field">
    <Switch.Root
      class="switch-root"
      bind:checked={fiddleState.keepCopyright}
      disabled={!fiddleState.stripMetadata}
    >
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span class:muted-label={!fiddleState.stripMetadata}>Keep copyright (kcr)</span>
  </label>

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={fiddleState.stripColorProfile}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Strip color profile (scp)</span>
  </label>

  <label class="field">
    <span>Color profile (cp)</span>
    <select bind:value={fiddleState.colorProfile}>
      <option value="none">none</option>
      <option value="srgb">srgb</option>
      <option value="display-p3">display-p3</option>
      <option value="adobe-rgb">adobe-rgb</option>
    </select>
  </label>

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={fiddleState.preserveHdr}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Preserve HDR (ph)</span>
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

    code {
      font-family: var(--font-mono);
      font-size: 11px;
    }
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

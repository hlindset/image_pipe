<script lang="ts">
  import { Switch } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import { cropPixelLimit, type SourceImage } from "./processing-path";
  import {
    iiifControlLimits,
    iiifRegionSegment,
    iiifSizeSegment,
    type IiifState,
    type IiifRegion,
    type IiifSize,
  } from "./iiif-path";

  type Props = {
    iiifState: IiifState;
    source: SourceImage;
  };

  let { iiifState = $bindable(), source }: Props = $props();

  const widthLimit = $derived(cropPixelLimit(source, "width"));
  const heightLimit = $derived(cropPixelLimit(source, "height"));

  // Section summaries mirror the URL tokens they produce.
  const regionSummary = $derived(iiifRegionSegment(iiifState.region));
  const sizeSummary = $derived(iiifSizeSegment(iiifState.size, iiifState.upscale));
  const rotationSummary = $derived(
    `${iiifState.rotation.mirror ? "!" : ""}${iiifState.rotation.degrees}°`,
  );
  const outputSummary = $derived(`${iiifState.quality} · ${iiifState.format}`);

  function setRegionKind(kind: IiifRegion["kind"]): void {
    switch (kind) {
      case "full":
        iiifState.region = { kind: "full" };
        break;
      case "square":
        iiifState.region = { kind: "square" };
        break;
      case "px":
        iiifState.region = { kind: "px", x: 0, y: 0, w: widthLimit.max, h: heightLimit.max };
        break;
      case "pct":
        iiifState.region = { kind: "pct", x: 0, y: 0, w: 50, h: 50 };
        break;
    }
  }

  function setSizeKind(kind: IiifSize["kind"]): void {
    switch (kind) {
      case "max":
        iiifState.size = { kind: "max" };
        break;
      case "w":
        iiifState.size = { kind: "w", w: 400 };
        break;
      case "h":
        iiifState.size = { kind: "h", h: 300 };
        break;
      case "wh":
        iiifState.size = { kind: "wh", w: 400, h: 300 };
        break;
      case "confined":
        iiifState.size = { kind: "confined", w: 400, h: 300 };
        break;
      case "pct":
        iiifState.size = { kind: "pct", n: 50 };
        break;
    }
  }
</script>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Region</h2>
      <p>{regionSummary}</p>
    </div>
  </div>

  <label class="field">
    <span>Form</span>
    <select
      value={iiifState.region.kind}
      onchange={(e) => setRegionKind(e.currentTarget.value as IiifRegion["kind"])}
    >
      <option value="full">full</option>
      <option value="square">square</option>
      <option value="px">pixel (x,y,w,h)</option>
      <option value="pct">percent (x,y,w,h)</option>
    </select>
  </label>

  {#if iiifState.region.kind === "px"}
    <RangeNumber label="x" bind:value={iiifState.region.x} min={0} max={widthLimit.max} step={1} />
    <RangeNumber label="y" bind:value={iiifState.region.y} min={0} max={heightLimit.max} step={1} />
    <RangeNumber label="w" bind:value={iiifState.region.w} min={1} max={widthLimit.max} step={1} />
    <RangeNumber label="h" bind:value={iiifState.region.h} min={1} max={heightLimit.max} step={1} />
  {:else if iiifState.region.kind === "pct"}
    <RangeNumber
      label="x %"
      bind:value={iiifState.region.x}
      min={0}
      max={100}
      step={0.1}
      inputStep="any"
    />
    <RangeNumber
      label="y %"
      bind:value={iiifState.region.y}
      min={0}
      max={100}
      step={0.1}
      inputStep="any"
    />
    <RangeNumber
      label="w %"
      bind:value={iiifState.region.w}
      min={0.1}
      max={100}
      step={0.1}
      inputStep="any"
    />
    <RangeNumber
      label="h %"
      bind:value={iiifState.region.h}
      min={0.1}
      max={100}
      step={0.1}
      inputStep="any"
    />
  {/if}
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Size</h2>
      <p>{sizeSummary}</p>
    </div>
  </div>

  <label class="field">
    <span>Form</span>
    <select
      value={iiifState.size.kind}
      onchange={(e) => setSizeKind(e.currentTarget.value as IiifSize["kind"])}
    >
      <option value="max">max</option>
      <option value="w">width only (w,)</option>
      <option value="h">height only (,h)</option>
      <option value="wh">width × height (w,h)</option>
      <option value="confined">confined (!w,h)</option>
      <option value="pct">percent (pct:n)</option>
    </select>
  </label>

  {#if iiifState.size.kind === "w"}
    <RangeNumber
      label="Width"
      bind:value={iiifState.size.w}
      min={iiifControlLimits.size.min}
      max={iiifControlLimits.size.max}
      step={1}
      suffix="px"
    />
  {:else if iiifState.size.kind === "h"}
    <RangeNumber
      label="Height"
      bind:value={iiifState.size.h}
      min={iiifControlLimits.size.min}
      max={iiifControlLimits.size.max}
      step={1}
      suffix="px"
    />
  {:else if iiifState.size.kind === "wh" || iiifState.size.kind === "confined"}
    <RangeNumber
      label="Width"
      bind:value={iiifState.size.w}
      min={iiifControlLimits.size.min}
      max={iiifControlLimits.size.max}
      step={1}
      suffix="px"
    />
    <RangeNumber
      label="Height"
      bind:value={iiifState.size.h}
      min={iiifControlLimits.size.min}
      max={iiifControlLimits.size.max}
      step={1}
      suffix="px"
    />
  {:else if iiifState.size.kind === "pct"}
    <RangeNumber
      label="Percent"
      bind:value={iiifState.size.n}
      min={iiifControlLimits.pct.min}
      max={iiifControlLimits.pct.max}
      step={1}
      suffix="%"
    />
  {/if}

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={iiifState.upscale}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Allow upscaling (^)</span>
  </label>
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Rotation</h2>
      <p>{rotationSummary}</p>
    </div>
  </div>

  <RangeNumber label="Degrees" bind:value={iiifState.rotation.degrees} min={0} max={360} step={1} />

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={iiifState.rotation.mirror}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Mirror (!)</span>
  </label>
</section>

<section class="tool-section">
  <div class="accordion-heading">
    <div>
      <h2>Output</h2>
      <p>{outputSummary}</p>
    </div>
  </div>

  <label class="field">
    <span>Quality</span>
    <select bind:value={iiifState.quality}>
      <option value="default">default</option>
      <option value="color">color</option>
      <option value="gray">gray</option>
      <option value="bitonal">bitonal</option>
    </select>
  </label>

  <label class="field">
    <span>Format</span>
    <select bind:value={iiifState.format}>
      <option value="jpg">jpg</option>
      <option value="png">png</option>
      <option value="webp">webp</option>
      <option value="avif">avif</option>
    </select>
  </label>
</section>

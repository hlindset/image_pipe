<script lang="ts">
  // All controls for a `crop` step. Loads the running-image preview (the chain up
  // to, but not including, this crop) once to learn its pixel dimensions, so the
  // W/H and origin sliders are bounded by what's actually addressable rather than a
  // flat cap. The minimap origin picker reuses the same preview.
  import { Switch } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import TwicCropOriginPicker from "./TwicCropOriginPicker.svelte";

  type Props = {
    previewSrc: string;
    width: number; // crop width px [$bindable]
    height: number; // crop height px [$bindable]
    origin: { x: number; y: number } | null; // [$bindable]
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
    origin = on ? { x: 1, y: 1 } : null;
  }
</script>

<!-- Hidden loader so the W/H maxes track the running image even when origin is off
     (the visible minimap reuses the same — cached — preview). -->
<img class="dims-probe" src={previewSrc} alt="" aria-hidden="true" onload={onDimsLoad} />

<RangeNumber
  label="Width"
  bind:value={width}
  min={1}
  max={runningWidth > 0 ? runningWidth : 8000}
  step={1}
  suffix="px"
/>
<RangeNumber
  label="Height"
  bind:value={height}
  min={1}
  max={runningHeight > 0 ? runningHeight : 8000}
  step={1}
  suffix="px"
/>

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
</style>

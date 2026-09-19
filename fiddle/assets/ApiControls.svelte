<script lang="ts">
  import { untrack } from "svelte";
  import ApiVisualControls from "./ApiVisualControls.svelte";
  import {
    controlStateFromOptions,
    defaultControlState,
    normalizeControlEdit,
    optionGroups,
    updateControlOptions,
  } from "./api-controls";
  import type { ApiState } from "./api-path";

  let { apiState = $bindable() }: { apiState: ApiState } = $props();
  let groupIndex = $state(0);
  let controls = $state(structuredClone(defaultControlState));
  let baseline = structuredClone(defaultControlState);
  let lastOptions = "";
  let lastSource = "";
  let lastGroup = -1;
  const groups = $derived(optionGroups(apiState.options));

  $effect(() => {
    const options = apiState.options;
    const source = apiState.source;
    const index = groupIndex;
    untrack(() => {
      if (options === lastOptions && source === lastSource && index === lastGroup) return;
      groupIndex = Math.min(index, optionGroups(options).length - 1);
      controls = controlStateFromOptions(options, source, groupIndex);
      baseline = $state.snapshot(controls);
      lastOptions = options;
      lastSource = source;
      lastGroup = groupIndex;
    });
  });

  $effect(() => {
    const current = $state.snapshot(controls);
    untrack(() => {
      if (lastGroup < 0) return;
      const next = normalizeControlEdit(baseline, current);
      if (JSON.stringify(next) !== JSON.stringify(current)) controls = next;
      const options = updateControlOptions(lastOptions, lastGroup, baseline, next);
      baseline = next;
      if (options === lastOptions) return;
      if (optionGroups(options).length !== optionGroups(lastOptions).length) lastGroup = -1;
      lastOptions = options;
      apiState.options = options;
    });
  });

  type Example = {
    label: string;
    options: string;
    source?: ApiState["source"];
  };

  const examples: Example[] = [
    { label: "Resize", options: "w=800" },
    { label: "High density", options: "w=400/dpr=2/pad=20/bg=fff" },
    { label: "Zoom", options: "w=400/zoom=1.5" },
    { label: "Minimum size", options: "w=200/min-w=400/enlarge" },
    { label: "Square crop", options: "w=400/h=400/fit=cover" },
    { label: "Faces", options: "w=400/h=400/fit=cover/detect=face" },
    { label: "Objects", options: "w=400/h=400/fit=cover/detect=all" },
    { label: "Favor faces", options: "w=400/h=400/fit=cover/detect=all,face:3" },
    { label: "Face-assisted smart crop", options: "w=400/h=400/fit=cover/anchor=smart-face" },
    { label: "Crop ratio", options: "crop=80pct,80pct/crop-ratio=16:9/w=600" },
    {
      label: "Offset crop",
      options: "crop=60pct,60pct/anchor=top-left/anchor-offset=10pct,5pct/w=600",
    },
    { label: "Canvas", options: "w=600/h=600/extend/extend-at=bottom/bg=fff" },
    {
      label: "Wide canvas",
      options: "w=600/h=300/extend-ratio/extend-at=left/extend-offset=5pct,0/bg=fff",
    },
    { label: "Symmetric trim", options: "trim=auto/trim-symmetry=hv/w=600" },
    { label: "Blur", options: "w=800/blur=3" },
    { label: "Sharpen", options: "w=800/sharpen=2" },
    { label: "Pixelate", options: "w=600/pixelate=12" },
    { label: "Monochrome", options: "w=600/monochrome=0.8,704214" },
    { label: "Duotone", options: "w=600/duotone=1,123456,efab89" },
    { label: "Brightness", options: "w=600/brightness=30" },
    { label: "Contrast", options: "w=600/contrast=1.5" },
    { label: "Saturation", options: "w=600/saturation=0.5" },
    { label: "Color overlay", options: "w=600/colorize=0.3,red,keep-alpha" },
    { label: "Gradient", options: "w=600/gradient=0.8,black,down,0.2,0.9" },
    { label: "Padding", options: "w=600/pad=24/bg=fff" },
    { label: "Resize then trim", options: "w=500/then/trim=fff" },
    { label: "Framed preset", options: "preset=framed" },
    { label: "Rotate", options: "rotate=30/w=600" },
    { label: "Flip", options: "rotate=90/flip=h/w=600" },
    {
      label: "Stored orientation",
      options: "orient=none/w=600",
      source: "images/orientation-6.jpg",
    },
    { label: "Rotate then trim", options: "rotate=90/trim=auto/w=600" },
    { label: "Trim and crop", options: "trim=auto/crop=50pct,50pct/w=600" },
    { label: "Grayscale", options: "w=600/gray" },
    { label: "Black and white", options: "w=600/bitonal" },
    { label: "JPEG quality", options: "w=600/format=jpeg/q=60" },
    { label: "Format quality", options: "w=600/format-q=avif:60,webp:70,jxl:75" },
    { label: "Byte budget", options: "w=600/format=jpeg/max-bytes=20000/debug" },
    {
      label: "Size search",
      options: "w=600/format=jpeg/autoquality=size,target:20000,min:30,max:95/debug",
    },
    {
      label: "Perceptual quality",
      options: "w=600/format=jpeg/autoquality=ssimulacra2,target:80,min:50,max:95/debug",
    },
    {
      label: "JPEG XL distance",
      options: "w=600/format=jxl/autoquality=butteraugli,target:1/jxl-options=effort:3/debug",
    },
    { label: "Progressive JPEG", options: "w=600/format=jpeg/jpeg-options=progressive" },
    { label: "Palette PNG", options: "w=600/format=png/png-options=palette,bitdepth:4" },
    { label: "Lossless WebP", options: "w=600/format=webp/webp-options=lossless" },
    { label: "AVIF effort", options: "w=600/format=avif/avif-options=effort:3" },
    { label: "Keep metadata", options: "w=600/meta=keep" },
    { label: "Keep attribution", options: "w=600/meta=copyright" },
    { label: "Strip metadata", options: "w=600/meta=strip" },
    {
      label: "Keep Display P3",
      options: "w=400/format=png/profile=preserve",
      source: "images/display-p3.png",
    },
    { label: "Convert to sRGB", options: "w=600/profile=srgb" },
    { label: "Convert to Display P3", options: "w=600/profile=display-p3" },
    { label: "Convert to Adobe RGB", options: "w=600/profile=adobe-rgb" },
    {
      label: "Preserve 16-bit",
      options: "w=400/format=png/hdr=preserve/debug",
      source: "images/rgba16.png",
    },
    {
      label: "Tone map to 8-bit",
      options: "w=400/format=png/hdr=tonemap/debug",
      source: "images/rgba16.png",
    },
    { label: "Debug headers", options: "w=800/debug" },
    { label: "Source info", options: "output=info" },
    { label: "BlurHash", options: "w=100/output=blurhash" },
    { label: "Download image", options: "w=800/filename=sample/attachment" },
    { label: "Download info", options: "output=info/filename=source-info/attachment" },
    { label: "Cachebuster", options: "w=800/cb=v2/debug" },
  ];

  function applyExample(example: Example) {
    apiState = {
      ...apiState,
      options: example.options,
      source: example.source ?? apiState.source,
    };
  }
</script>

<section class="api-controls">
  <label class="field">
    <span>Examples</span>
    <select
      aria-label="Load example"
      value=""
      onchange={(event) => {
        const example = examples[Number(event.currentTarget.value)];
        if (example) applyExample(example);
        event.currentTarget.value = "";
      }}
    >
      <option value="" disabled>Choose an example…</option>
      {#each examples as example, index}
        <option value={index}>{example.label}</option>
      {/each}
    </select>
  </label>
  {#if groups.length > 1}
    <label class="field">
      <span>Processing group</span>
      <select bind:value={groupIndex}>
        {#each groups as _, index}
          <option value={index}>Group {index + 1}{index > 0 ? " · then" : ""}</option>
        {/each}
      </select>
    </label>
    <p>Geometry and effects apply to this group. Output settings apply to the whole request.</p>
  {/if}
</section>

<ApiVisualControls bind:controlState={controls} source={apiState.source} />

<details class="api-controls">
  <summary>Advanced · request path</summary>
  <label class="field">
    <span>Processing options</span>
    <textarea
      aria-label="Processing options"
      bind:value={apiState.options}
      rows="5"
      spellcheck="false"></textarea>
  </label>
  <p>Separate options with a slash. Use <code>then</code> to start another processing group.</p>
</details>

<style>
  .api-controls {
    padding: 14px;
    display: grid;
    gap: 14px;
    border-bottom: 1px solid var(--border-subtle);
  }
  details.api-controls {
    display: block;
  }
  summary {
    cursor: pointer;
    font-size: 13px;
    color: var(--text-label);
  }
  details[open] summary {
    margin-bottom: 14px;
  }
  textarea {
    width: 100%;
    box-sizing: border-box;
    resize: vertical;
    font-family: monospace;
    line-height: 1.5;
    padding: 0.75rem;
    color: var(--text-primary);
    background: var(--surface-control);
    border: 1px solid var(--border-strong);
    border-radius: 0.5rem;
  }
  p {
    font-size: 0.8rem;
    line-height: 1.5;
    color: var(--text-muted);
  }
  :where(textarea, summary):focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>

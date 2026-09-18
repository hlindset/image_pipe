<script lang="ts">
  import type { NativeState } from "./native-path";

  let { nativeState = $bindable() }: { nativeState: NativeState } = $props();

  type Example = {
    label: string;
    options: string;
    source?: NativeState["source"];
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
    { label: "Debug headers", options: "w=800/debug" },
  ];

  function applyExample(example: Example) {
    nativeState = {
      ...nativeState,
      options: example.options,
      source: example.source ?? nativeState.source,
    };
  }
</script>

<section class="native-controls">
  <label>
    <span>Processing options</span>
    <textarea
      aria-label="Native processing options"
      bind:value={nativeState.options}
      rows="5"
      spellcheck="false"
      placeholder="w=800/format=webp"
    ></textarea>
  </label>
  <p>Separate options with a slash. Use <code>then</code> to start another processing group.</p>
  <div class="examples">
    {#each examples as example}
      <button type="button" class="quiet-button" onclick={() => applyExample(example)}>
        {example.label}
      </button>
    {/each}
  </div>
</section>

<style>
  .native-controls {
    padding: 1rem;
  }
  label {
    display: grid;
    gap: 0.5rem;
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
  .examples {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
  }
  .quiet-button {
    padding: 0.5rem 0.75rem;
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-button-quiet);
    color: var(--text-primary);
    font: inherit;
    font-size: 0.8rem;
    cursor: pointer;
  }
  .quiet-button:hover {
    color: var(--text-heading);
    border-color: var(--text-muted);
  }
  :where(textarea, .quiet-button):focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }
</style>

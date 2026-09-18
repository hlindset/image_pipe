<script lang="ts">
  import type { NativeState } from "./native-path";

  let { nativeState = $bindable() }: { nativeState: NativeState } = $props();

  const examples = [
    { label: "Resize", options: "w=800" },
    { label: "Square crop", options: "w=400/h=400/fit=cover" },
    { label: "Blur", options: "w=800/blur=3" },
    { label: "Padding", options: "w=600/pad=24/bg=fff" },
    { label: "Resize then trim", options: "w=500/then/trim=fff" },
    { label: "Framed preset", options: "preset=framed" },
    { label: "Rotate", options: "rotate=30/w=600" },
    { label: "Grayscale", options: "w=600/gray" },
    { label: "Black and white", options: "w=600/bitonal" },
  ];
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
      <button
        type="button"
        class="quiet-button"
        onclick={() => (nativeState.options = example.options)}
      >
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

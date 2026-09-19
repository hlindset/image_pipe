<script lang="ts">
  type Props = {
    title: string;
    summary: string;
    checked: boolean;
    onCheckedChange?: ((checked: boolean) => void) | undefined;
  };

  let { title, summary, checked = $bindable(), onCheckedChange = undefined }: Props = $props();

  function toggleChecked(): void {
    const nextChecked = !checked;

    checked = nextChecked;
    onCheckedChange?.(nextChecked);
  }
</script>

<button
  class="tool-toggle-heading"
  class:is-checked={checked}
  type="button"
  aria-pressed={checked}
  aria-label={`${checked ? "Disable" : "Enable"} ${title.toLowerCase()}`}
  onclick={toggleChecked}
>
  <span class="tool-toggle-text">
    <h2>{title}</h2>
    <p>{summary}</p>
  </span>
  <span class="switch-root" aria-hidden="true">
    <span class="switch-thumb"></span>
  </span>
</button>

<style>
  .tool-toggle-heading {
    min-height: 20px;
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    border: 0;
    background: transparent;
    color: inherit;
    cursor: pointer;
    font: inherit;
    padding: 0;
    text-align: start;

    :where(h2, p) {
      margin: 0;
    }

    h2 {
      color: var(--text-heading);
      font-size: 16px;
      font-weight: 600;
      line-height: 20px;
    }

    p {
      margin-block-start: 2px;
      color: var(--text-muted);
      font-family: var(--font-mono);
      font-size: 12px;
      line-height: 16px;
      /* Long summaries (e.g. detection with many classes) must truncate
         rather than push the toggle switch out of bounds. */
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    &:focus-visible {
      border-radius: 6px;
      outline: 2px solid var(--focus-ring);
      outline-offset: 4px;
    }
  }

  .tool-toggle-text {
    /* min-width: 0 lets this flex item shrink so the summary `p` can ellipsize
       instead of forcing width and pushing the switch out of bounds. */
    min-width: 0;
    flex: 1;
  }

  .switch-root {
    width: 42px;
    height: 24px;
    display: flex;
    flex-shrink: 0;
    align-items: center;
    justify-content: flex-start;
    border-radius: 999px;
    background: var(--surface-control-track);
    padding: 2px;
    transition: background-color 120ms ease-out;
  }

  .switch-thumb {
    display: block;
    width: 20px;
    height: 20px;
    border-radius: 999px;
    background: var(--text-muted);
    transition:
      transform 140ms cubic-bezier(0.2, 0.9, 0.24, 1),
      background-color 120ms ease-out;
  }

  .tool-toggle-heading.is-checked .switch-root {
    background: var(--accent);
  }

  .tool-toggle-heading.is-checked .switch-thumb {
    background: var(--surface-sidebar);
    transform: translateX(18px);
  }

  @media (prefers-reduced-motion: reduce) {
    .switch-root,
    .switch-thumb {
      transition-duration: 1ms;
    }
  }
</style>

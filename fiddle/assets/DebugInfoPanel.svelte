<script lang="ts">
  import { type DebugGroup } from "./debug-headers";

  let { groups }: { groups: DebugGroup[] | null } = $props();
</script>

{#if groups !== null}
  <div class="debug-panel">
    {#each groups as group (group.title)}
      <section class="debug-group">
        <h4 class="debug-group-title">{group.title}</h4>
        <dl class="debug-rows">
          {#each group.rows as detail (detail.label)}
            <div class="debug-row">
              <dt>{detail.label}</dt>
              <dd>{detail.value}</dd>
            </div>
          {/each}
        </dl>
      </section>
    {/each}
  </div>
{:else}
  <p class="debug-empty">No debug headers available for this response.</p>
{/if}

<style>
  .debug-empty {
    margin: 0;
    font-size: 12px;
    color: var(--text-muted);
  }

  .debug-group-title {
    margin: 0 0 4px;
    font-size: 11px;
    letter-spacing: 0.04em;
    color: var(--text-muted);
  }

  .debug-rows {
    margin: 0 0 10px;
    display: grid;
    gap: 2px;
  }

  .debug-group:last-child .debug-rows {
    margin-bottom: 0;
  }

  .debug-row {
    display: grid;
    grid-template-columns: 120px 1fr;
    gap: 8px;
    font-size: 12px;
  }

  .debug-row dt {
    color: var(--text-muted);
  }

  .debug-row dd {
    margin: 0;
    color: var(--text-primary);
    font-family: var(--font-mono);
    font-variant-numeric: tabular-nums;
    overflow-wrap: anywhere;
  }
</style>

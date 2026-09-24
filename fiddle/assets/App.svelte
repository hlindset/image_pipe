<script lang="ts">
  import { onMount } from "svelte";
  import { Collapsible, Popover, RadioGroup } from "bits-ui";
  import ApiControls from "./ApiControls.svelte";
  import {
    apiFetchPath,
    ApiPathResolution,
    resolveApiFetchPath,
    resetApiSettings,
    type Protection,
  } from "./api-path";
  import {
    appPathForState,
    defaultAppState,
    parseAppPath,
    type AppState,
  } from "./fiddle-url-state";
  import {
    debounce,
    debouncePreviewPath,
    processedSizeLabel,
    type ProcessedImageMetadata,
  } from "./preview-metadata";
  import { sampleImages, type SourceImage, type SourceType } from "./source";
  import {
    PreviewMetadataTracker,
    registerPreviewWorker,
    type PreviewWorker,
  } from "./preview-bridge";
  import DebugInfoPanel from "./DebugInfoPanel.svelte";
  import { parseDebugHeaders } from "./debug-headers";
  import { isTextPreview, readTextPreview, type TextPreview } from "./text-preview";
  import LqipCssPreview from "./LqipCssPreview.svelte";
  import {
    applyThemeMode,
    persistThemeMode,
    readStoredThemeMode,
    storedThemeMode,
    type ThemeMode,
  } from "./theme";

  let copyLabel = $state("Copy URL");
  let drawerOpen = $state(false);
  let mobileTools = $state(false);
  let requestOpen = $state(true);
  let themeMode: ThemeMode = $state(readStoredThemeMode());
  const initial = initialAppState();
  const initialPath = initial.api.protection === "unsigned" ? apiFetchPath(initial.api) : null;
  let appState: AppState = $state(initial);
  let path: string | null = $state(initialPath);
  let previewBasePath: string | null = $state(initialPath);
  let previewImageUrl: string | null = $state(null);
  let previewLoading = $state(true);
  let previewError: string | null = $state(null);
  let processedMetadata: ProcessedImageMetadata | null = $state(null);
  let textPreview: TextPreview | null = $state(null);
  // Element references bound via bind:this.
  let toolsSidebar: HTMLElement | null = $state(null);
  let menuButton: HTMLButtonElement | null = $state(null);
  let drawerCloseButton: HTMLButtonElement | null = $state(null);
  // Internal, non-reactive bookkeeping: request-id guards, timers, and the
  // preview-metadata tracker + service-worker handle. Nothing reactive reads these.
  let copyLabelResetTimeout: number | null = null;
  const previewMetadata = new PreviewMetadataTracker();
  let previewWorker: PreviewWorker | null = null;
  let previewWorkerDisposed = false; // guards the register-promise-vs-unmount race
  let currentRequestId = 0;
  let lastPreviewAbsolute: string | null = null; // dedupe on resolved URL, not raw path
  let textPreviewController: AbortController | null = null;
  const pathResolution = new ApiPathResolution();
  const updatePreviewPath = debouncePreviewPath((previewRequestPath: string) => {
    const absolute = new URL(previewRequestPath, window.location.origin).href;
    // Dedupe on the RESOLVED url (not the raw path): a no-op must never flip
    // previewLoading=true without a following <img> load event, or the spinner
    // would strand. This same absolute is the SW-message correlation key.
    if (absolute === lastPreviewAbsolute) return;
    lastPreviewAbsolute = absolute;
    currentRequestId = previewMetadata.begin(absolute);
    previewLoading = true;
    previewError = null;
    processedMetadata = null;
    textPreview = null;
    textPreviewController?.abort();
    if (isTextPreview(previewRequestPath)) {
      previewImageUrl = null;
      textPreviewController = new AbortController();
      void loadTextPreview(absolute, currentRequestId, textPreviewController.signal);
    } else {
      textPreviewController = null;
      previewImageUrl = absolute;
    }
  }, 150);

  async function loadTextPreview(url: string, requestId: number, signal: AbortSignal) {
    try {
      const response = await fetch(url, { signal });
      const result = await readTextPreview(response);
      if (signal.aborted || requestId !== currentRequestId) return;
      textPreview = result;
      previewLoading = false;
    } catch (error) {
      if (signal.aborted || requestId !== currentRequestId) return;
      lastPreviewAbsolute = null;
      previewError = error instanceof Error ? error.message : "Unable to load preview";
      previewLoading = false;
    }
  }
  const updateFiddleLocation = debounce((nextPath: string) => {
    if (
      typeof window === "undefined" ||
      window.location.pathname + window.location.search === nextPath
    ) {
      return;
    }

    window.history.replaceState(null, "", nextPath);
  }, 150);

  onMount(() => {
    const mediaQuery = window.matchMedia("(max-width: 720px)");
    const syncMobileTools = () => {
      mobileTools = mediaQuery.matches;
    };

    syncMobileTools();
    mediaQuery.addEventListener("change", syncMobileTools);
    window.addEventListener("popstate", restoreStateFromLocation);
    restoreStateFromLocation();

    void registerPreviewWorker((message) => {
      if (textPreviewController !== null) return;
      previewMetadata.applyMessage(message, currentRequestId);
      // Reflect late-arriving bytes/contentType (and SW-reported errors) into the UI.
      if (previewMetadata.metadata !== null) processedMetadata = previewMetadata.metadata;
      if (previewMetadata.error !== null) {
        previewError = previewMetadata.error;
        processedMetadata = null;
        previewLoading = false; // an SW error may arrive before the <img> error event
      }
    }).then((worker) => {
      // If the component already unmounted while register/ready was awaiting, the
      // cleanup ran with previewWorker still null and could not unsubscribe — do it
      // here so the global navigator.serviceWorker listener can't leak across HMR.
      if (previewWorkerDisposed) {
        worker.unsubscribe();
        return;
      }
      previewWorker = worker;
    });

    return () => {
      mediaQuery.removeEventListener("change", syncMobileTools);
      window.removeEventListener("popstate", restoreStateFromLocation);
      previewWorkerDisposed = true;
      previewWorker?.unsubscribe();
      textPreviewController?.abort();
    };
  });

  $effect(() => {
    const requestState = { ...appState.api };
    const pending = pathResolution.begin(requestState);
    setResolvedPath(pending.path);

    if (pending.path !== null) return;

    void resolveApiFetchPath(requestState)
      .then((resolvedPath) => {
        const currentPath = pathResolution.accept(pending.requestId, resolvedPath);
        if (currentPath === null) return;
        setResolvedPath(currentPath);
      })
      .catch((error) => {
        if (!pathResolution.reject(pending.requestId)) return;
        previewError = error instanceof Error ? error.message : "Unable to protect preview request";
        previewLoading = false;
      });
  });
  $effect(() => {
    updatePreviewPath(previewBasePath);
  });
  $effect(() => {
    updateFiddleLocation(appPathForState(appState));
  });
  $effect(() => {
    applyThemeMode(themeMode);
  });
  $effect(() => {
    persistThemeMode(themeMode);
  });

  const previewParameters = $derived(
    path?.replace(/^\/(?:image|image-signed)\//, "") ?? "Preparing protected request…",
  );
  const outputLabel = $derived.by(() =>
    textPreview !== null
      ? textPreview.contentType
      : (processedMetadata?.contentType?.split("/")[1] ?? "auto"),
  );
  const sizeLabel = $derived.by(
    () =>
      previewError ??
      (textPreview !== null
        ? `${textPreview.bytes.toLocaleString()} bytes`
        : processedSizeLabel(processedMetadata)),
  );
  const debugGroups = $derived.by(() => {
    const meta = textPreview ?? processedMetadata;
    return parseDebugHeaders(meta?.debugHeaders ?? null, meta?.bytes ?? null);
  });
  const requestSummary = $derived(appState.api.source.replace(/^images\//, ""));
  const currentSource = $derived(appState.api.source);
  const currentSourceType = $derived(appState.api.sourceType);

  function initialAppState(): AppState {
    if (typeof window === "undefined") {
      return defaultAppState();
    }

    return parseAppPath(window.location.pathname);
  }

  function restoreStateFromLocation(): void {
    appState = parseAppPath(window.location.pathname);
  }

  function onPreviewLoaded(image: HTMLImageElement): void {
    previewMetadata.applyDimensions(
      { width: image.naturalWidth, height: image.naturalHeight },
      currentRequestId,
    );
    processedMetadata = previewMetadata.metadata;
    previewError = previewMetadata.error;
    previewLoading = false;
  }

  function onPreviewError(): void {
    // <img> gives no detail; if the SW already reported an error for this request, show it.
    previewError = previewMetadata.error ?? "Preview request failed";
    processedMetadata = null;
    previewLoading = false;
    lastPreviewAbsolute = null; // allow reverting to a failed URL to retry it
  }

  async function copyGeneratedUrl(): Promise<void> {
    if (path === null) return;
    const absoluteUrl = new URL(path, window.location.origin).toString();

    await navigator.clipboard.writeText(absoluteUrl);
    showCopyLabel("Copied");
  }

  function copyUrl(): void {
    copyGeneratedUrl().catch(() => {
      showCopyLabel("Copy failed");
    });
  }

  function showCopyLabel(label: string): void {
    if (copyLabelResetTimeout !== null) {
      window.clearTimeout(copyLabelResetTimeout);
    }

    copyLabel = label;
    copyLabelResetTimeout = window.setTimeout(() => {
      copyLabel = "Copy URL";
      copyLabelResetTimeout = null;
    }, 1200);
  }

  function updateSource(event: Event): void {
    const select = event.currentTarget;

    if (!(select instanceof HTMLSelectElement)) {
      return;
    }

    const source = select.value as SourceImage;
    appState.api = { ...appState.api, source };
  }

  function updateSourceType(event: Event): void {
    const select = event.currentTarget;
    if (!(select instanceof HTMLSelectElement)) return;
    const sourceType = select.value as SourceType;
    appState.api = { ...appState.api, sourceType };
  }

  function updateProtection(event: Event): void {
    const select = event.currentTarget;
    if (!(select instanceof HTMLSelectElement)) return;
    const protection = select.value as Protection;
    appState.api = { ...appState.api, protection };
  }

  function setResolvedPath(resolvedPath: string | null): void {
    path = resolvedPath;
    previewBasePath = resolvedPath;

    if (resolvedPath !== null) return;

    previewImageUrl = null;
    textPreview = null;
    processedMetadata = null;
    previewError = null;
    previewLoading = true;
    currentRequestId = previewMetadata.begin("");
    textPreviewController?.abort();
    textPreviewController = null;
    lastPreviewAbsolute = null;
  }

  function setThemeMode(nextMode: string): void {
    themeMode = storedThemeMode(nextMode);
  }

  function resetSettings(): void {
    appState.api = resetApiSettings(appState.api);
  }

  function closeTools(): void {
    drawerOpen = false;

    if (mobileTools) {
      window.requestAnimationFrame(() => menuButton?.focus());
    }
  }

  function openTools(): void {
    drawerOpen = true;

    if (mobileTools) {
      window.requestAnimationFrame(() => drawerCloseButton?.focus());
    }
  }

  function handleToolsKeydown(event: KeyboardEvent): void {
    if (!mobileTools || !drawerOpen) {
      return;
    }

    if (event.key === "Escape") {
      event.preventDefault();
      closeTools();
      return;
    }

    if (event.key === "Tab") {
      trapDrawerFocus(event);
    }
  }

  function trapDrawerFocus(event: KeyboardEvent): void {
    if (toolsSidebar === null) {
      return;
    }

    const focusableElements = Array.from(
      toolsSidebar.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      ),
    ).filter((element) => element.getClientRects().length > 0 && element.tabIndex >= 0);
    const firstElement = focusableElements[0];
    const lastElement = focusableElements.at(-1);

    if (firstElement === undefined || lastElement === undefined) {
      return;
    }

    if (event.shiftKey && document.activeElement === firstElement) {
      event.preventDefault();
      lastElement.focus();
    } else if (!event.shiftKey && document.activeElement === lastElement) {
      event.preventDefault();
      firstElement.focus();
    }
  }
</script>

<main class="fiddle-shell">
  <button
    class="mobile-scrim"
    class:is-open={drawerOpen}
    type="button"
    tabindex={drawerOpen ? 0 : -1}
    aria-hidden={drawerOpen ? "false" : "true"}
    aria-label="Close tools"
    onclick={closeTools}
  ></button>

  <aside
    class="tools-sidebar"
    class:is-open={drawerOpen}
    aria-label="Processing controls"
    aria-hidden={mobileTools && !drawerOpen ? "true" : "false"}
    inert={mobileTools && !drawerOpen}
    bind:this={toolsSidebar}
    onkeydown={handleToolsKeydown}
  >
    <div class="drawer-topbar">
      <strong>Tools</strong>
      <button
        class="icon-button"
        type="button"
        aria-label="Close tools"
        bind:this={drawerCloseButton}
        onclick={closeTools}
      >
        ×
      </button>
    </div>

    <div class="sidebar-header">
      <strong>ImagePipe API</strong>
    </div>

    <div class="tool-stack">
      <section class="tool-section">
        <Collapsible.Root class="collapsible-root" bind:open={requestOpen}>
          <Collapsible.Trigger
            class="accordion-heading"
            aria-label={requestOpen ? "Collapse request" : "Expand request"}
          >
            <div>
              <h2>Request</h2>
              <p>{requestSummary}</p>
            </div>
            <span class="accordion-chevron" aria-hidden="true"></span>
          </Collapsible.Trigger>

          <Collapsible.Content class="collapsible-content">
            <label class="field">
              <span>Source image</span>
              <select value={currentSource} onchange={updateSource}>
                {#each sampleImages as image}
                  <option value={image.path}>{image.label}</option>
                {/each}
              </select>
            </label>

            <label class="field">
              <span>Source type</span>
              <select value={currentSourceType} onchange={updateSourceType}>
                <option value="local">Local (filesystem)</option>
                <option value="s3">S3 (s3proxy)</option>
                <option value="http">HTTP (Plug.Static)</option>
              </select>
            </label>

            <label class="field">
              <span>Protection</span>
              <select value={appState.api.protection} onchange={updateProtection}>
                <option value="unsigned">Unsigned</option>
                <option value="signed">Signed</option>
                <option value="signed-concealed">Signed + concealed source (stable)</option>
                <option value="signed-concealed-random">Signed + concealed source (random)</option>
              </select>
            </label>
            <p class="field-help">
              Protected previews use fixed demo-only keys held by this server.
            </p>
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      <ApiControls bind:apiState={appState.api} />
    </div>

    <div class="drawer-actions">
      <button class="quiet-button" type="button" onclick={resetSettings}>Reset</button>
      <button class="copy-button" type="button" onclick={copyUrl} disabled={path === null}
        >{copyLabel}</button
      >
      {#if path !== null}
        <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
      {/if}
    </div>
  </aside>

  <section
    class="preview-workspace"
    aria-label="Processed image preview"
    aria-hidden={mobileTools && drawerOpen ? "true" : "false"}
    inert={mobileTools && drawerOpen}
  >
    <header class="preview-command-bar">
      <button
        class="icon-button menu-button"
        type="button"
        aria-label="Open tools"
        bind:this={menuButton}
        onclick={openTools}
      >
        ☰
      </button>
      <div class="url-preview">
        <code class="parameter-preview">{previewParameters}</code>
        <Popover.Root>
          <Popover.Trigger class="debug-trigger" aria-label="Debug headers" title="Debug headers">
            <svg class="debug-trigger-icon" viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="9"></circle>
              <path d="M12 8h.01"></path>
              <path d="M11 12h1v4h1"></path>
            </svg>
          </Popover.Trigger>
          <Popover.Portal>
            <Popover.Content class="debug-popover" align="start" sideOffset={8}>
              <DebugInfoPanel groups={debugGroups} />
            </Popover.Content>
          </Popover.Portal>
        </Popover.Root>
      </div>
      <div class="preview-actions">
        <RadioGroup.Root
          class="theme-toggle"
          value={themeMode}
          onValueChange={setThemeMode}
          orientation="horizontal"
          aria-label="Theme"
        >
          <RadioGroup.Item class="theme-toggle-item" value="light" aria-label="Light theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <circle cx="12" cy="12" r="4"></circle>
              <path d="M12 2v3"></path>
              <path d="M12 19v3"></path>
              <path d="m4.93 4.93 2.12 2.12"></path>
              <path d="m16.95 16.95 2.12 2.12"></path>
              <path d="M2 12h3"></path>
              <path d="M19 12h3"></path>
              <path d="m4.93 19.07 2.12-2.12"></path>
              <path d="m16.95 7.05 2.12-2.12"></path>
            </svg>
          </RadioGroup.Item>
          <RadioGroup.Item class="theme-toggle-item" value="dark" aria-label="Dark theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M20 14.2A8.2 8.2 0 0 1 9.8 4 8.5 8.5 0 1 0 20 14.2Z"></path>
            </svg>
          </RadioGroup.Item>
          <RadioGroup.Item class="theme-toggle-item" value="system" aria-label="System theme">
            <svg class="theme-toggle-icon" viewBox="0 0 24 24" aria-hidden="true">
              <rect x="4" y="5" width="16" height="11" rx="2"></rect>
              <path d="M9 20h6"></path>
              <path d="M12 16v4"></path>
            </svg>
          </RadioGroup.Item>
        </RadioGroup.Root>
        <div class="desktop-actions">
          <button class="quiet-button" type="button" onclick={resetSettings}>Reset</button>
          <button
            class="copy-button copy-button-secondary"
            type="button"
            onclick={copyUrl}
            disabled={path === null}>{copyLabel}</button
          >
          {#if path !== null}
            <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
          {/if}
        </div>
      </div>
    </header>

    <div class="preview-canvas">
      <div class="preview-metadata" aria-live="polite">
        <span>{sizeLabel}</span>
        <span>{outputLabel}</span>
      </div>
      <div class="image-frame">
        <figure class:text-output={textPreview !== null}>
          {#if textPreview !== null}
            {#if /^#[0-9a-f]{8}$/.test(textPreview.text)}
              <LqipCssPreview value={textPreview.text} />
            {/if}
            <pre class="text-preview">{textPreview.text}</pre>
          {:else if previewImageUrl !== null}
            <img
              class:is-loading={previewLoading}
              src={previewImageUrl}
              alt="Processed sample source"
              onload={(event) => onPreviewLoaded(event.currentTarget as HTMLImageElement)}
              onerror={onPreviewError}
            />
          {/if}
        </figure>
      </div>
      {#if previewError !== null}
        <div class="preview-error" role="status">{previewError}</div>
      {/if}
      {#if previewLoading}
        <div class="preview-spinner" role="status" aria-label="Loading preview"></div>
      {/if}
    </div>
  </section>
</main>

<style>
  .text-preview {
    max-width: 100%;
    margin: 0;
    padding: 1.5rem;
    overflow-wrap: anywhere;
    white-space: pre-wrap;
    text-align: left;
    color: var(--text-primary);
    background: var(--surface-control);
    border: 1px solid var(--border-subtle);
    border-radius: 0.5rem;
  }

  .fiddle-shell {
    width: 100%;
    height: 100dvh;
    display: flex;
    overflow: hidden;
    background: var(--surface-app);
  }

  .tools-sidebar {
    width: 332px;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
    background: var(--surface-sidebar);
    border-inline-end: 1px solid var(--border-subtle);
    color: var(--text-primary);
  }

  .drawer-topbar {
    display: none;
  }

  /* Fixed title bar at the top of the sidebar; height matches the preview
     command bar so the two form one continuous header row. Lives outside
     .tool-stack so it doesn't scroll with the controls. */
  .sidebar-header {
    height: 64px;
    display: flex;
    align-items: center;
    flex-shrink: 0;
    padding-inline: 18px;
    border-block-end: 1px solid var(--border-subtle);
    background: var(--surface-bar);
  }

  .tool-stack {
    min-height: 0;
    flex: 1;
    padding: 18px;
    overflow-y: auto;
    scrollbar-width: thin;
    scrollbar-color: var(--border-strong) transparent;
  }

  .tool-stack::-webkit-scrollbar {
    width: 10px;
  }

  .tool-stack::-webkit-scrollbar-thumb {
    border: 3px solid var(--surface-sidebar);
    border-radius: 999px;
    background: var(--border-strong);
  }

  .preview-workspace {
    min-width: 0;
    height: 100dvh;
    flex: 1;
    display: flex;
    flex-direction: column;
    background: var(--surface-app);
  }

  .preview-command-bar {
    height: 64px;
    display: flex;
    align-items: center;
    gap: 14px;
    flex-shrink: 0;
    padding-block: 12px;
    padding-inline: 18px;
    border-block-end: 1px solid var(--border-subtle);
    background: var(--surface-bar);
  }

  .url-preview {
    min-width: 0;
    flex: 1;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .parameter-preview {
    min-width: 0;
    flex: 0 1 auto;
    overflow: hidden;
    color: var(--text-muted);
    font-size: 13px;
    line-height: 18px;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  :global(.debug-trigger) {
    flex-shrink: 0;
    width: 32px;
    height: 32px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-strong);
    border-radius: 8px;
    background: var(--surface-button-quiet);
    color: var(--text-muted);
    cursor: pointer;
  }

  :global(.debug-trigger:hover),
  :global(.debug-trigger[data-state="open"]) {
    color: var(--text-heading);
  }

  :global(.debug-trigger:focus-visible) {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  .debug-trigger-icon {
    width: 18px;
    height: 18px;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }

  :global(.debug-popover) {
    max-width: min(420px, calc(100vw - 24px));
    max-height: var(--bits-popover-content-available-height);
    overflow-y: auto;
    padding: 14px;
    border: 1px solid var(--border-strong);
    border-radius: 10px;
    background: var(--surface-sidebar);
    box-shadow: var(--image-shadow);
    z-index: 50;
  }

  .desktop-actions,
  .drawer-actions,
  .preview-actions {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .preview-actions {
    flex-shrink: 0;
  }

  .preview-actions :global(.theme-toggle) {
    height: 36px;
    display: inline-flex;
    align-items: center;
    gap: 2px;
    padding: 3px;
    border: 1px solid var(--border-strong);
    border-radius: 999px;
    background: var(--surface-button-quiet);
  }

  .preview-actions :global(.theme-toggle-item) {
    width: 28px;
    height: 28px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 0;
    border-radius: 999px;
    background: transparent;
    color: var(--text-muted);
    cursor: pointer;
    padding: 0;
  }

  .preview-actions :global(.theme-toggle-item[data-state="checked"]) {
    background: var(--surface-control);
    color: var(--text-heading);
    box-shadow: 0 0 0 1px var(--border-subtle);
  }

  .theme-toggle-icon {
    width: 16px;
    height: 16px;
    display: block;
    fill: none;
    stroke: currentColor;
    stroke-linecap: round;
    stroke-linejoin: round;
    stroke-width: 2;
  }

  .drawer-actions {
    display: none;
  }

  .copy-button,
  .open-link,
  .quiet-button,
  .icon-button {
    border: 0;
    border-radius: 8px;
    cursor: pointer;
    text-decoration: none;
  }

  .copy-button,
  .open-link,
  .quiet-button {
    height: 40px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0 16px;
    font-size: 14px;
    line-height: 18px;
    font-weight: 700;
  }

  .copy-button {
    min-width: 104px;
    background: var(--button-secondary-bg);
    color: var(--button-secondary-text);
  }

  .quiet-button {
    min-width: 76px;
    background: transparent;
    color: var(--text-muted);
  }

  .quiet-button:hover {
    background: var(--surface-button-quiet);
    color: var(--text-heading);
  }

  .copy-button-secondary {
    background: var(--button-secondary-bg);
  }

  .open-link {
    min-width: 76px;
    background: var(--button-primary-bg);
    color: var(--button-primary-text);
  }

  .icon-button {
    width: 36px;
    height: 36px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border: 1px solid var(--border-strong);
    background: var(--surface-button-quiet);
    color: var(--text-primary);
    font-size: 18px;
    line-height: 1;
  }

  .menu-button {
    display: none;
  }

  .preview-canvas {
    position: relative;
    min-height: 0;
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    padding: 28px;
    background: repeating-conic-gradient(var(--checker-square) 0 25%, var(--surface-canvas) 0 50%)
      50% / 20px 20px;
  }

  .preview-metadata {
    position: absolute;
    z-index: 1;
    inset-inline: 28px;
    inset-block-end: 24px;
    display: flex;
    justify-content: space-between;
    gap: 12px;
    color: var(--image-overlay-text);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 16px;
    pointer-events: none;
    text-shadow: var(--image-overlay-shadow);
  }

  .image-frame {
    max-width: calc(100% - 48px);
    max-height: calc(100% - 48px);
    display: flex;
    align-items: center;
    justify-content: center;

    figure {
      position: relative;
      display: inline-flex;
      margin: 0;
      box-shadow: var(--image-shadow);
    }

    figure.text-output {
      min-width: 0;
      max-width: 100%;
      flex-direction: column;
      align-items: center;
      gap: 12px;
      box-shadow: none;
    }

    img {
      display: block;
      width: auto;
      height: auto;
      max-width: 100%;
      max-height: calc(100dvh - 160px);
      transition:
        opacity 120ms ease-out,
        filter 120ms ease-out;
    }

    img.is-loading {
      opacity: 0.54;
      filter: saturate(0.82);
    }
  }

  .preview-spinner {
    position: absolute;
    z-index: 2;
    inset-block-start: 50%;
    inset-inline-start: 50%;
    width: 36px;
    height: 36px;
    border: 3px solid color-mix(in srgb, var(--image-overlay-text) 32%, transparent);
    border-block-start-color: var(--accent);
    border-radius: 999px;
    pointer-events: none;
    transform: translate(-50%, -50%);
    animation: preview-spin 650ms linear infinite;
  }

  .preview-error {
    position: absolute;
    z-index: 2;
    inset-inline: 28px;
    inset-block-start: 28px;
    max-width: min(640px, calc(100% - 56px));
    border: 1px solid color-mix(in srgb, var(--danger) 42%, transparent);
    border-radius: 8px;
    background: color-mix(in srgb, var(--surface-bar) 92%, transparent);
    color: var(--danger);
    font-family: var(--font-mono);
    font-size: 12px;
    line-height: 16px;
    padding: 10px 12px;
    text-wrap: pretty;
    box-shadow: var(--image-shadow);
  }

  @keyframes preview-spin {
    to {
      transform: translate(-50%, -50%) rotate(1turn);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .preview-spinner {
      animation-duration: 1.5s;
    }
  }

  .fiddle-shell :global(.switch-root) {
    width: 42px;
    height: 24px;
    display: flex;
    flex-shrink: 0;
    align-items: center;
    justify-content: flex-start;
    border: 0;
    border-radius: 999px;
    background: var(--surface-control-track);
    padding: 2px;
    cursor: pointer;
    transition: background-color 120ms ease-out;
  }

  .fiddle-shell :global(.switch-root[data-state="checked"]) {
    background: var(--accent);
  }

  .fiddle-shell :global(.switch-thumb) {
    display: block;
    width: 20px;
    height: 20px;
    border-radius: 999px;
    background: var(--text-muted);
    transition:
      transform 140ms cubic-bezier(0.2, 0.9, 0.24, 1),
      background-color 120ms ease-out;
  }

  .fiddle-shell :global(.switch-root[data-state="checked"] .switch-thumb) {
    background: var(--surface-sidebar);
    transform: translateX(18px);
  }

  .fiddle-shell :global(.switch-root:focus-visible),
  .fiddle-shell :global(.accordion-heading:focus-visible),
  .fiddle-shell :global(.theme-toggle-item:focus-visible),
  :where(.copy-button, .open-link, .quiet-button, .icon-button, select):focus-visible {
    outline: 2px solid var(--focus-ring);
    outline-offset: 2px;
  }

  @media (prefers-reduced-motion: reduce) {
    .fiddle-shell :global(.switch-root),
    .fiddle-shell :global(.switch-thumb) {
      transition-duration: 1ms;
    }
  }

  .mobile-scrim {
    display: none;
  }

  @media (max-width: 720px) {
    .tools-sidebar {
      position: fixed;
      z-index: 3;
      inset-block: 0;
      inset-inline-start: 0;
      width: min(326px, calc(100vw - 48px));
      transform: translateX(-100%);
      transition: transform 180ms ease;
      box-shadow: var(--drawer-shadow);
    }

    .tools-sidebar.is-open {
      transform: translateX(0);
    }

    .drawer-topbar {
      height: 52px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      flex-shrink: 0;
      padding-block: 8px;
      padding-inline: 14px;
      border-block-end: 1px solid var(--border-subtle);
      background: var(--surface-sidebar);
    }

    .drawer-topbar strong {
      font-size: 14px;
      line-height: 18px;
    }

    .tool-stack {
      height: auto;
      flex: 1;
      padding: 0 18px;
    }

    .drawer-actions {
      height: 61px;
      display: flex;
      flex-shrink: 0;
      padding-block: 12px;
      padding-inline: 14px;
      border-block-start: 1px solid var(--border-subtle);
      background: var(--surface-sidebar);
    }

    .drawer-actions .copy-button {
      flex: 1;
    }

    .mobile-scrim {
      position: fixed;
      z-index: 2;
      inset: 0;
      display: block;
      border: 0;
      background: var(--scrim);
      opacity: 0;
      pointer-events: none;
      transition: opacity 180ms ease;
    }

    .mobile-scrim.is-open {
      opacity: 1;
      pointer-events: auto;
    }

    .preview-workspace {
      width: 100%;
    }

    .preview-command-bar {
      height: 58px;
      gap: 10px;
      padding-block: 10px;
      padding-inline: 12px;
    }

    .menu-button {
      display: inline-flex;
      width: 40px;
      height: 38px;
    }

    .desktop-actions {
      display: none;
    }

    .preview-actions {
      margin-inline-start: auto;
      gap: 0;
    }

    .parameter-preview {
      font-size: 11px;
      line-height: 14px;
    }

    .preview-canvas {
      padding: 18px;
    }

    .image-frame {
      max-width: 100%;
      max-height: 100%;
    }

    .image-frame img {
      max-height: calc(100dvh - 140px);
    }

    .preview-metadata {
      inset-inline: 18px;
      inset-block-end: 16px;
      font-size: 11px;
      line-height: 14px;
    }
  }
</style>

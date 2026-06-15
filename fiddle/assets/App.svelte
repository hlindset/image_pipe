<script lang="ts">
  import { onMount } from "svelte";
  import { Collapsible, RadioGroup } from "bits-ui";
  import ImgproxyControls from "./ImgproxyControls.svelte";
  import IiifControls from "./IiifControls.svelte";
  import TwicPicsControls from "./TwicPicsControls.svelte";
  import {
    appPathForState,
    defaultAppState,
    parseAppPath,
    providers,
    resetFiddleSettings,
    type AppState,
  } from "./fiddle-url-state";
  import { defaultIiifState, iiifFetchPath } from "./iiif-path";
  import { defaultTwicPicsState, twicFetchPath } from "./twicpics-path";
  import {
    buildProcessingPath,
    debounce,
    processedSizeLabel,
    processingPathFromSignedPath,
    resetCropPixelsToSource,
    sampleImages,
    signProcessingPath,
    signedPathForState,
    resolvedOutputLabel,
    type FiddleState,
    type ProcessedImageMetadata,
    type SourceImage,
  } from "./processing-path";
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
  let appState: AppState = $state(initial);
  let path = $state(
    initial.provider === "imgproxy"
      ? buildProcessingPath(initial.imgproxy)
      : initial.provider === "iiif"
        ? iiifFetchPath(initial.iiif)
        : twicFetchPath(initial.twicpics),
  );
  let previewImageUrl: string | null = $state(null);
  let previewLoading = $state(true);
  let previewError: string | null = $state(null);
  let processedMetadata: ProcessedImageMetadata | null = $state(null);
  let signingError: string | null = $state(null);
  // Element references bound via bind:this.
  let toolsSidebar: HTMLElement | null = $state(null);
  let menuButton: HTMLButtonElement | null = $state(null);
  let drawerCloseButton: HTMLButtonElement | null = $state(null);
  // Internal, non-reactive bookkeeping: request-id guards, timers and the
  // abort/object-url handles. Nothing reactive reads these, so they stay plain locals.
  let previewPath = "";
  let metadataRequestId = 0;
  let pathRequestId = 0;
  let copyLabelResetTimeout: number | null = null;
  let activePreviewObjectUrl: string | null = null;
  let previewAbortController: AbortController | null = null;
  const updatePreviewPath = debounce((nextPath: string) => {
    if (nextPath !== previewPath) {
      processedMetadata = null;
      previewError = null;
      metadataRequestId += 1;
      previewLoading = true;
    }

    void loadPreview(nextPath);
  }, 150);
  const updateFiddleLocation = debounce((nextPath: string) => {
    if (
      typeof window === "undefined" ||
      window.location.pathname + window.location.search === nextPath
    ) {
      return;
    }

    window.history.replaceState(null, "", nextPath);
  }, 150);
  const previewAcceptHeader = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";

  onMount(() => {
    const mediaQuery = window.matchMedia("(max-width: 720px)");
    const syncMobileTools = () => {
      mobileTools = mediaQuery.matches;
    };

    syncMobileTools();
    mediaQuery.addEventListener("change", syncMobileTools);
    window.addEventListener("popstate", restoreStateFromLocation);
    restoreStateFromLocation();

    return () => {
      mediaQuery.removeEventListener("change", syncMobileTools);
      window.removeEventListener("popstate", restoreStateFromLocation);
      previewAbortController?.abort();
      revokePreviewObjectUrl();
    };
  });

  $effect(() => {
    if (appState.provider === "imgproxy") {
      updateProcessingPath(appState.imgproxy);
    } else if (appState.provider === "iiif") {
      pathRequestId += 1; // invalidate any in-flight imgproxy signing so it can't clobber `path`
      path = iiifFetchPath(appState.iiif);
    } else {
      pathRequestId += 1; // invalidate any in-flight imgproxy signing so it can't clobber `path`
      path = twicFetchPath(appState.twicpics);
    }
  });
  $effect(() => {
    updatePreviewPath(path);
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
    appState.provider === "imgproxy"
      ? path.replace(/^\/[^/]+\/[^/]+\//, "")
      : appState.provider === "iiif"
        ? path.replace(/^\/iiif-image\//, "")
        : path.replace(/^\/twic\//, ""),
  );
  const outputLabel = $derived(
    appState.provider === "imgproxy"
      ? resolvedOutputLabel(appState.imgproxy, processedMetadata)
      : appState.provider === "iiif"
        ? appState.iiif.format
        : appState.twicpics.output,
  );
  const sizeLabel = $derived(previewError ?? processedSizeLabel(processedMetadata));
  const requestSummary = $derived(
    appState.provider === "imgproxy"
      ? `${appState.imgproxy.source.replace(/^images\//, "")} / ${requestSignatureLabel(appState.imgproxy, signingError)}`
      : appState.provider === "iiif"
        ? appState.iiif.source.replace(/^images\//, "")
        : appState.twicpics.source.replace(/^images\//, ""),
  );
  const currentSource = $derived(
    appState.provider === "iiif"
      ? appState.iiif.source
      : appState.provider === "twicpics"
        ? appState.twicpics.source
        : appState.imgproxy.source,
  );

  function initialAppState(): AppState {
    if (typeof window === "undefined") {
      return defaultAppState();
    }

    return parseAppPath(window.location.pathname, window.location.search);
  }

  function restoreStateFromLocation(): void {
    const parsed = parseAppPath(window.location.pathname, window.location.search);

    switch (parsed.provider) {
      case "iiif":
        appState = {
          provider: "iiif",
          imgproxy: appState.imgproxy,
          iiif: parsed.iiif,
          twicpics: appState.twicpics,
        };
        break;
      case "twicpics":
        appState = {
          provider: "twicpics",
          imgproxy: appState.imgproxy,
          iiif: appState.iiif,
          twicpics: parsed.twicpics,
        };
        break;
      default:
        appState = {
          provider: "imgproxy",
          imgproxy: parsed.imgproxy,
          iiif: appState.iiif,
          twicpics: appState.twicpics,
        };
    }
  }

  function requestSignatureLabel(
    currentState: FiddleState,
    currentSigningError: string | null,
  ): string {
    if (currentState.signatureMode === "signed") {
      return currentSigningError === null ? "signed" : "signed: invalid key";
    }

    return currentState.signatureMode;
  }

  function updateProcessingPath(currentState: FiddleState): void {
    const requestId = ++pathRequestId;
    const signedPath = signedPathForState(currentState);

    if (currentState.signatureMode !== "signed") {
      signingError = null;
      path = buildProcessingPath(currentState);
      return;
    }

    signProcessingPath(signedPath, currentState.signatureKey, currentState.signatureSalt)
      .then((signature) => {
        if (requestId === pathRequestId) {
          signingError = null;
          path = processingPathFromSignedPath(signature, signedPath);
        }
      })
      .catch((error: unknown) => {
        if (requestId === pathRequestId) {
          signingError = error instanceof Error ? error.message : "Unable to sign request";
          path = processingPathFromSignedPath("invalid-signature", signedPath);
        }
      });
  }

  async function loadPreview(nextPath: string): Promise<void> {
    const requestId = ++metadataRequestId;
    previewAbortController?.abort();
    const abortController = new AbortController();
    let objectUrl: string | null = null;

    previewAbortController = abortController;
    previewPath = nextPath;
    previewLoading = true;
    previewError = null;
    processedMetadata = null;

    try {
      const response = await fetch(nextPath, {
        cache: "no-cache",
        headers: { accept: previewAcceptHeader },
        signal: abortController.signal,
      });
      const contentType = response.headers.get("content-type");

      if (!response.ok) {
        const message = await previewErrorFromResponse(response);

        if (requestId === metadataRequestId) {
          previewLoading = false;
          previewError = message;
          processedMetadata = null;
        }

        return;
      }

      const blob = await response.blob();
      objectUrl = URL.createObjectURL(blob);
      const dimensions = await imageDimensions(objectUrl);

      if (requestId === metadataRequestId) {
        revokePreviewObjectUrl();
        activePreviewObjectUrl = objectUrl;
        previewImageUrl = objectUrl;
        previewLoading = false;
        processedMetadata = {
          ...dimensions,
          bytes: blob.size,
          contentType: contentType ?? blob.type ?? null,
        };
        objectUrl = null;
      } else {
        URL.revokeObjectURL(objectUrl);
        objectUrl = null;
      }
    } catch (error) {
      if (objectUrl !== null) {
        URL.revokeObjectURL(objectUrl);
      }

      if (error instanceof DOMException && error.name === "AbortError") {
        return;
      }

      if (requestId === metadataRequestId) {
        previewLoading = false;
        previewError = previewErrorMessage(error);
        processedMetadata = null;
      }
    } finally {
      if (previewAbortController === abortController) {
        previewAbortController = null;
      }
    }
  }

  async function previewErrorFromResponse(response: Response): Promise<string> {
    const status = `${response.status} ${response.statusText || "Preview request failed"}`;

    try {
      const body = (await response.text()).trim();

      if (body !== "") {
        return `${status}: ${body.slice(0, 180)}`;
      }
    } catch {
      return status;
    }

    return status;
  }

  function previewErrorMessage(error: unknown): string {
    return error instanceof Error ? error.message : "Preview request failed";
  }

  function imageDimensions(objectUrl: string): Promise<{ width: number; height: number }> {
    return new Promise((resolve, reject) => {
      const image = new Image();

      image.onload = () => resolve({ width: image.naturalWidth, height: image.naturalHeight });
      image.onerror = () => reject(new Error("Preview image could not be decoded"));
      image.src = objectUrl;
    });
  }

  function revokePreviewObjectUrl(): void {
    if (activePreviewObjectUrl !== null) {
      URL.revokeObjectURL(activePreviewObjectUrl);
      activePreviewObjectUrl = null;
    }
  }

  async function copyGeneratedUrl(): Promise<void> {
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
    // Source is shared, so update BOTH slices (not just the active one) — switching
    // provider later then shows the selected image — and reset each provider's
    // source-dimension-bound pixels (imgproxy crop, IIIF px region).
    appState.imgproxy = resetCropPixelsToSource({ ...appState.imgproxy, source });
    appState.iiif = { ...appState.iiif, source, region: { kind: "full" } };
    appState.twicpics = { ...appState.twicpics, source };
  }

  function setThemeMode(nextMode: string): void {
    themeMode = storedThemeMode(nextMode);
  }

  function resetSettings(): void {
    if (appState.provider === "imgproxy") {
      appState.imgproxy = resetFiddleSettings(appState.imgproxy);
    } else if (appState.provider === "iiif") {
      appState.iiif = { ...defaultIiifState, source: appState.iiif.source };
    } else {
      appState.twicpics = { ...defaultTwicPicsState, source: appState.twicpics.source };
    }
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
      <select aria-label="Provider" bind:value={appState.provider}>
        {#each providers as provider}
          <option value={provider.id}>{provider.label}</option>
        {/each}
      </select>
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

            {#if appState.provider === "imgproxy"}
              <label class="field">
                <span>Signature</span>
                <select bind:value={appState.imgproxy.signatureMode}>
                  <option value="unsigned">unsigned</option>
                  <option value="signed">signed</option>
                </select>
              </label>

              {#if appState.imgproxy.signatureMode === "signed"}
                <div class="signature-secret-grid">
                  <label class="field">
                    <span>Key</span>
                    <input
                      class="text-input text-input-mono"
                      bind:value={appState.imgproxy.signatureKey}
                      spellcheck="false"
                      autocomplete="off"
                    />
                  </label>

                  <label class="field">
                    <span>Salt</span>
                    <input
                      class="text-input text-input-mono"
                      bind:value={appState.imgproxy.signatureSalt}
                      spellcheck="false"
                      autocomplete="off"
                    />
                  </label>
                </div>

                {#if signingError !== null}
                  <p class="field-error">{signingError}</p>
                {/if}
              {/if}
            {/if}
          </Collapsible.Content>
        </Collapsible.Root>
      </section>

      {#if appState.provider === "imgproxy"}
        <ImgproxyControls bind:fiddleState={appState.imgproxy} source={appState.imgproxy.source} />
      {:else if appState.provider === "iiif"}
        <IiifControls bind:iiifState={appState.iiif} source={appState.iiif.source} />
      {:else}
        <TwicPicsControls
          bind:twicpicsState={appState.twicpics}
          source={appState.twicpics.source}
        />
      {/if}
    </div>

    <div class="drawer-actions">
      <button class="quiet-button" type="button" onclick={resetSettings}>Reset</button>
      <button class="copy-button" type="button" onclick={copyUrl}>{copyLabel}</button>
      <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
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
      <code class="parameter-preview">{previewParameters}</code>
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
          <button class="copy-button copy-button-secondary" type="button" onclick={copyUrl}
            >{copyLabel}</button
          >
          <a class="open-link" href={path} target="_blank" rel="noreferrer">Open</a>
        </div>
      </div>
    </header>

    <div class="preview-canvas">
      <div class="preview-metadata" aria-live="polite">
        <span>{sizeLabel}</span>
        <span>{outputLabel}</span>
      </div>
      <div class="image-frame">
        <figure>
          {#if previewImageUrl !== null}
            <img
              class:is-loading={previewLoading}
              src={previewImageUrl}
              alt="Processed sample source"
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

  /* Fixed provider bar at the top of the sidebar; height matches the preview
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

  .parameter-preview {
    min-width: 0;
    flex: 1;
    overflow: hidden;
    color: var(--text-muted);
    font-size: 13px;
    line-height: 18px;
    text-overflow: ellipsis;
    white-space: nowrap;
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

  .signature-secret-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 12px;
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

  .text-input-mono {
    font-family: var(--font-mono);
    font-size: 12px;
  }

  .field-error {
    margin: 0;
    color: var(--accent);
    font-size: 12px;
    line-height: 16px;
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
  :where(.copy-button, .open-link, .quiet-button, .icon-button, select, .text-input):focus-visible {
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

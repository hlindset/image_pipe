import { defineConfig } from "vite";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const currentDirectory = dirname(fileURLToPath(import.meta.url));

// One-shot build (NOT the dev server): emit a single, unhashed, root-served worker.
// emptyOutDir:false so we never wipe priv/static (images, main-app manifest).
export default defineConfig({
  build: {
    outDir: resolve(currentDirectory, "../priv/static"),
    emptyOutDir: false,
    manifest: false,
    rollupOptions: {
      input: resolve(currentDirectory, "preview-sw.ts"),
      output: { entryFileNames: "preview-sw.js", format: "iife" },
    },
  },
});

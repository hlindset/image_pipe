import { svelte } from "@sveltejs/vite-plugin-svelte";
import { phoenixVitePlugin } from "phoenix_vite";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { imageSize } from "image-size";
import { transformWithOxc, type Plugin } from "vite";

const currentDirectory = dirname(fileURLToPath(import.meta.url));
const sampleImagesModuleId = "virtual:sample-images";
const resolvedSampleImagesModuleId = `\0${sampleImagesModuleId}.ts`;
const sampleImageExtensions = new Set([".avif", ".jpeg", ".jpg", ".png", ".webp"]);
const maxFiddleOriginBytes = 10_000_000;
const maxFiddleInputPixels = 40_000_000;

function sampleImagesPlugin(
  imagesDirectory = resolve(currentDirectory, "../priv/static/images"),
): Plugin {
  return {
    name: "sample-images",
    resolveId(id) {
      if (id === sampleImagesModuleId) return resolvedSampleImagesModuleId;
      return null;
    },
    async load(id) {
      if (id === resolvedSampleImagesModuleId) {
        const transformed = await transformWithOxc(
          buildSampleImagesModule(imagesDirectory),
          "sample-images.ts",
        );
        return transformed.code;
      }
      return null;
    },
    configureServer(server) {
      server.watcher.add(imagesDirectory);
      server.watcher.on("all", (_event, changedPath) => {
        if (relative(imagesDirectory, changedPath).startsWith("..")) return;
        const m = server.moduleGraph.getModuleById(resolvedSampleImagesModuleId);
        if (m !== undefined) {
          server.moduleGraph.invalidateModule(m);
          server.ws.send({ type: "full-reload" });
        }
      });
    },
  };
}

function buildSampleImagesModule(imagesDirectory: string): string {
  const sampleImages = readdirSync(imagesDirectory)
    .filter((fileName) => sampleImageExtensions.has(fileExtension(fileName)))
    .sort((left, right) => left.localeCompare(right))
    .flatMap((fileName) => {
      const filePath = join(imagesDirectory, fileName);
      const fileSize = statSync(filePath).size;
      if (fileSize > maxFiddleOriginBytes) return [];
      const dimensions = imageSize(readFileSync(filePath));
      if (dimensions.width === undefined || dimensions.height === undefined) {
        throw new Error(`Could not read image dimensions for ${filePath}`);
      }
      if (dimensions.width * dimensions.height > maxFiddleInputPixels) return [];
      return [
        {
          path: `images/${encodeURIComponent(fileName)}`,
          label: fileName,
          width: dimensions.width,
          height: dimensions.height,
        },
      ];
    });
  return `export const sampleImages = ${JSON.stringify(sampleImages, null, 2)} as const;\n`;
}

function fileExtension(fileName: string): string {
  const lastDotIndex = fileName.lastIndexOf(".");
  if (lastDotIndex === -1) return "";
  return fileName.slice(lastDotIndex).toLowerCase();
}

export default defineConfig({
  base: "/",
  plugins: [sampleImagesPlugin(), svelte(), phoenixVitePlugin({ pattern: /\.(ex|heex)$/ })],
  server: {
    host: "localhost",
    port: 5173,
    origin: "http://localhost:5173",
    strictPort: true,
    cors: { origin: "http://localhost:4000" },
  },
  build: {
    manifest: true,
    outDir: "../priv/static",
    emptyOutDir: false,
    rollupOptions: {
      input: ["main.ts"],
    },
  },
  test: {
    include: ["**/*.test.ts"],
  },
});

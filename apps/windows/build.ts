import { rm } from "node:fs/promises";
import { join } from "node:path";

const outdir = join(import.meta.dir, "dist");
await rm(outdir, { recursive: true, force: true });
// ws loads these native accelerators optionally; the bundle runs without them.
const external = ["electron", "bufferutil", "utf-8-validate"];
const builds = [
  { entrypoints: ["src/main.ts"], naming: "main.js", target: "node", format: "esm" },
  { entrypoints: ["src/preload.ts"], naming: "preload.cjs", target: "node", format: "cjs" },
  { entrypoints: ["src/renderer.ts"], naming: "renderer.js", target: "browser", format: "esm" },
] as const;
for (const options of builds) {
  const result = await Bun.build({ ...options, entrypoints: options.entrypoints.map(path => join(import.meta.dir, path)), outdir, external });
  if (!result.success) {
    for (const message of result.logs) console.error(message);
    process.exit(1);
  }
}
console.log(`Built ${outdir}`);

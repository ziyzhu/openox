import { rm } from "node:fs/promises";
import { join } from "node:path";

const outputDirectory = join(import.meta.dir, "dist");
await rm(outputDirectory, { recursive: true, force: true });

const result = await Bun.build({
  entrypoints: [join(import.meta.dir, "src", "ox.ts")],
  outdir: outputDirectory,
  naming: "ox.js",
  target: "bun",
  external: ["@sinclair/typebox", "@sinclair/typebox/*", "typescript"],
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

console.log(`Built ${result.outputs[0]?.path ?? outputDirectory}`);

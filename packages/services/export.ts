import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { buildArtifacts } from "./src/build.ts";

const args = Bun.argv.slice(2);
const outputIndex = args.indexOf("--output");
const outputArgument = outputIndex >= 0 ? args[outputIndex + 1] : undefined;
if (!outputArgument) throw new Error("Usage: bun packages/services/export.ts --output <new-directory> [--web-only]");
const output = resolve(outputArgument);
if (existsSync(output)) throw new Error(`export destination already exists: ${output}`);
const repository = await buildArtifacts(output, {
  name: "Built-in",
  ...(args.includes("--web-only") ? { catalogKinds: [] } : {}),
});
console.log(`exported ${output} services=${repository.services.length} hash=${repository.contentHash?.slice(0, 12)}`);

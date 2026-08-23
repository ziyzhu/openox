import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { buildArtifacts } from "./build.ts";

const args = Bun.argv.slice(2);
const outputIndex = args.indexOf("--output");
const outputArgument = outputIndex >= 0 ? args[outputIndex + 1] : undefined;
if (!outputArgument) throw new Error("Usage: bun services/export.ts --output <new-directory>");
const output = resolve(outputArgument);
if (existsSync(output)) throw new Error(`export destination already exists: ${output}`);
const repository = await buildArtifacts(output, { name: "Built-in" });
console.log(`exported ${output} services=${repository.services.length} hash=${repository.contentHash?.slice(0, 12)}`);

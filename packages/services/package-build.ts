import { rm } from "node:fs/promises";
import { join } from "node:path";
import { buildArtifacts } from "./src/build.ts";

const outputDirectory = join(import.meta.dir, "dist");
await rm(outputDirectory, { recursive: true, force: true });
const repository = await buildArtifacts(join(outputDirectory, "repository"), { name: "Built-in" });
console.log(`Built ${repository.services.length} services at ${outputDirectory}`);

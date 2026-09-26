import { runCheck, run } from "./lib.ts";
import { check as hostContract } from "./ios-host-contract-check.ts";
import { check as localizations } from "./localization-check.ts";
import { check as providerModels } from "./provider-models.ts";
import { check as providerSchema } from "./provider-definitions.ts";
import { check as publicBoundary } from "./public-boundary-check.ts";
import { check as systemSkills } from "./system-skills-check.ts";

for (const check of [publicBoundary, hostContract, systemSkills, localizations, providerModels, providerSchema]) {
  await runCheck(check);
}

const projects = [
  "apps/cli/tsconfig.json",
  "packages/service-sdk/tsconfig.json",
  "packages/services/tsconfig.json",
  "tooling/tsconfig.json",
  "evals/tsconfig.json",
];

const results = await Promise.all(projects.map(async (project) => {
  const { code } = await run(["bunx", "tsc", "-p", project], { allowFailure: true });
  return { project, code };
}));

const failed = results.filter((result) => result.code !== 0);
if (failed.length > 0) {
  for (const result of failed) console.error(`FAIL typecheck ${result.project} exited ${result.code}`);
  process.exitCode = 1;
} else {
  console.log(`PASS typecheck ${projects.length} projects`);
}

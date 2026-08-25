import { ROOT } from "./lib.ts";
import { validateLocalizations } from "./localization-check.ts";
import { validateBundledModelsDevCatalog } from "./models-dev-catalog.ts";
import { validateSystemSkills } from "./system-skills-check.ts";

const boundary = Bun.spawnSync(["bun", "tooling/public-boundary-check.ts"], { cwd: ROOT, stdout: "inherit", stderr: "inherit" });
if (boundary.exitCode !== 0) process.exit(boundary.exitCode);

const hostContract = Bun.spawnSync(["bun", "tooling/ios-host-contract-check.ts"], { cwd: ROOT, stdout: "inherit", stderr: "inherit" });
if (hostContract.exitCode !== 0) process.exit(hostContract.exitCode);

const systemSkills = await validateSystemSkills();
console.log(`PASS system skills ${systemSkills} packages`);

const localizationEntries = await validateLocalizations();
console.log(`PASS localizations ${localizationEntries} entries`);

const catalog = await validateBundledModelsDevCatalog();
console.log(`PASS models.dev catalog selected=${catalog.selectedModels}`);

const projects = [
  "apps/cli/tsconfig.json",
  "packages/service-sdk/tsconfig.json",
  "packages/services/tsconfig.json",
  "tooling/tsconfig.json",
  "apps/ios/tests/llm/tsconfig.json",
  "packages/services/tests/tsconfig.json",
];

const results = await Promise.all(projects.map(async (project) => {
  const process = Bun.spawn({
    cmd: ["bunx", "tsc", "-p", project],
    cwd: ROOT,
    stdout: "inherit",
    stderr: "inherit",
  });
  return { project, code: await process.exited };
}));

const failed = results.filter((result) => result.code !== 0);
if (failed.length > 0) {
  for (const result of failed) console.error(`FAIL typecheck ${result.project} exited ${result.code}`);
  process.exitCode = 1;
} else {
  console.log(`PASS typecheck ${projects.length} projects`);
}

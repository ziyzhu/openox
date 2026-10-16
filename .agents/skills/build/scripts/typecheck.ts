import { runCheck, run } from "../../../lib.ts";
import { check as hostContract } from "./ios-host-contract-check.ts";
import { check as hostPlatforms } from "./host-platform-boundary-check.ts";
import { check as hostSchema } from "./host-rpc-contract.ts";
import { check as repositoryContract } from "./repository-contract.ts";
import { check as localizations } from "./localization-check.ts";
import { check as providers } from "./providers.ts";
import { check as providerSchema } from "./provider-definitions.ts";
import { check as publicBoundary } from "./public-boundary-check.ts";
import { check as filesystemPaths } from "./filesystem-path-check.ts";
import { check as skills } from "./skills-check.ts";

for (const check of [publicBoundary, hostPlatforms, hostContract, hostSchema, repositoryContract, filesystemPaths, skills, localizations, providers, providerSchema]) {
  await runCheck(check);
}

const projects = [
  "apps/cli/tsconfig.json",
  "packages/protocol/tsconfig.json",
  "packages/agent/tsconfig.json",
  "packages/services/tsconfig.json",
  ".agents/tsconfig.json",
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

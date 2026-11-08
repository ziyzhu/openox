import { run, runCheck } from "../../../lib.ts";
import { check as publicBoundary } from "./public-boundary-check.ts";
import { check as hostPlatforms } from "./host-platform-boundary-check.ts";
import { check as hostContract } from "./ios-host-contract-check.ts";
import { check as filesystemPaths } from "./filesystem-path-check.ts";
import { check as skills } from "./skills-check.ts";
import { check as localizations } from "./localization-check.ts";
import { check as providers } from "./providers.ts";
import { check as services } from "./services-check.ts";

for (const check of [publicBoundary, hostPlatforms, hostContract, filesystemPaths, skills, localizations, providers, services]) {
  await runCheck(check);
}

await run(["bun", "--no-env-file", ".agents/skills/build/scripts/typecheck.ts"]);
await run(["bun", "--no-env-file", ".agents/skills/evals/scripts/runner.ts", "--validate"]);

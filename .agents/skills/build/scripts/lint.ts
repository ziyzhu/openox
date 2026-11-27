import { run, runCheck } from "../../../lib.ts";
import { check as publicBoundary } from "./public-boundary-check.ts";
import { check as sourcePolicy } from "./source-policy-check.ts";
import { check as hostPlatforms } from "./platform-boundary-check.ts";
import { check as hostContract } from "./ios-runtime-contract-check.ts";
import { check as filesystemPaths } from "./filesystem-path-check.ts";
import { check as skills } from "./skills-check.ts";
import { check as localizations } from "./localization-check.ts";
import { check as providers } from "./providers.ts";
import { check as services } from "./services-check.ts";
import { check as androidParity } from "./android-parity-check.ts";

for (const check of [publicBoundary, sourcePolicy, hostPlatforms, hostContract, filesystemPaths, skills, localizations, providers, services, androidParity]) {
  await runCheck(check);
}

await run(["bun", "--no-env-file", ".agents/skills/build/scripts/typecheck.ts"]);

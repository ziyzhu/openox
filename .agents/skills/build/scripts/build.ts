import { run, runCheck } from "../../../lib.ts";
import { check as hostSchema } from "./profile-rpc-contract.ts";
import { check as repositoryContract } from "./repository-contract.ts";
import { check as providerSchema } from "./provider-definitions.ts";

for (const check of [hostSchema, repositoryContract, providerSchema]) {
  await runCheck(check);
}

await run(["bun", "--no-env-file", "run", "build:services"]);
await run(["bun", "--no-env-file", "run", "build:agent"]);
for (const workspace of ["packages/protocol", "packages/services", "apps/cli"]) {
  await run(["bun", "--no-env-file", "run", "--cwd", workspace, "package:check"]);
}

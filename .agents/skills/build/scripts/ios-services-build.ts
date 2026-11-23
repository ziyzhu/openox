import { cp, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { refreshBuiltinRepository } from "../../../../packages/services/src/build.ts";
import { BUILTIN_REPOSITORY_ROOT } from "../../../../packages/services/src/service.ts";
import { ROOT } from "../../../lib.ts";
import { STANDARD_WEB_ACTION_SCHEMAS } from "../../../../packages/protocol/src/model-actions.ts";

const sourceSkills = join(ROOT, "packages/agent/skills");
const bundledSkills = join(BUILTIN_REPOSITORY_ROOT, "skills");
await writeFile(join(ROOT, "apps/shared/Resources/ModelServiceActions.json"), `${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n`);
await writeFile(join(sourceSkills, "evolve/references/model-schemas.md"),
  `# Standard website Action schemas\n\nGenerated from packages/protocol/src/model-actions.ts by bun run build:services. conversation is the service submit/read/cancel Action; listModels lists website choices without registering an Ox model provider. Legacy model-generation schemas remain for installed-service validation only. Copy exact schemas; do not mix protocols on one conversation page.\n\n\`\`\`json\n${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n\`\`\`\n`);
await rm(bundledSkills, { recursive: true, force: true });
await cp(sourceSkills, bundledSkills, { recursive: true });
const repository = await refreshBuiltinRepository();
console.log(`Validated ${BUILTIN_REPOSITORY_ROOT} services=${repository.services.length} skills=${repository.skills.length} hash=${repository.contentHash?.slice(0, 12)}`);

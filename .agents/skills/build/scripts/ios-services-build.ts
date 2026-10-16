import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { refreshBuiltinRepository } from "../../../../packages/services/src/build.ts";
import { BUILTIN_REPOSITORY_ROOT } from "../../../../packages/services/src/service.ts";
import { ROOT } from "../../../lib.ts";
import { STANDARD_WEB_ACTION_SCHEMAS } from "../../../../packages/protocol/src/model-actions.ts";

const repository = await refreshBuiltinRepository();
await writeFile(join(ROOT, "apps/shared/Resources/ModelServiceActions.json"), `${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n`);
await writeFile(join(ROOT, "packages/agent/skills/evolve/references/model-schemas.md"),
  `# Standard website Action schemas\n\nGenerated from packages/protocol/src/model-actions.ts by bun run build:services. conversation is the service submit/read/cancel Action; listModels lists website choices without registering an Ox model provider. Legacy model-generation schemas remain for installed-service validation only. Copy exact schemas; do not mix protocols on one conversation page.\n\n\`\`\`json\n${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n\`\`\`\n`);
console.log(`Validated ${BUILTIN_REPOSITORY_ROOT} services=${repository.services.length} hash=${repository.contentHash?.slice(0, 12)}`);

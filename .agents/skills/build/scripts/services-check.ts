import { join } from "node:path";
import { ROOT, runCheck } from "../../../lib.ts";
import { buildService, BUILTIN_REPOSITORY_ROOT } from "../../../../packages/services/src/service.ts";
import { loadIOSManifest, loadMCPManifest } from "../../../../packages/services/src/catalog.ts";
import { validateRepositoryPackage, repositoryServiceKind, repositoryServiceIdentity } from "../../../../packages/protocol/src/repository.ts";

export async function check(): Promise<string> {
  const repository = validateRepositoryPackage(await Bun.file(join(BUILTIN_REPOSITORY_ROOT, "repository.json")).json());
  if ("error" in repository) throw new Error(repository.error);
  const failures: string[] = [];
  for (const service of repository.services) {
    const kind = repositoryServiceKind(service);
    const identity = repositoryServiceIdentity(service);
    const result = kind === "ios" ? await loadIOSManifest(service)
      : kind === "mcp" ? await loadMCPManifest(identity)
      : await buildService(kind === "api" ? service : identity);
    if ("error" in result) failures.push(`${service}: ${result.error}`);
  }
  if (failures.length) throw new Error(failures.join("\n"));
  return `service contracts and installers ${repository.services.length} services`;
}

if (import.meta.main) {
  process.chdir(ROOT);
  await runCheck(check);
}

import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { refreshBuiltinRepository } from "../../../../packages/services/src/build.ts";
import { BUILTIN_REPOSITORY_ROOT } from "../../../../packages/services/src/service.ts";
import { ROOT, run } from "../../../lib.ts";
import { STANDARD_WEB_ACTION_SCHEMAS } from "../../../../packages/protocol/src/model-actions.ts";

const destination = join(BUILTIN_REPOSITORY_ROOT, "Repositories.bundle");
const temporary = await mkdtemp(join(tmpdir(), "ox-local-repository-seed-"));
const staging = join(temporary, "Repositories.bundle");
const backup = join(temporary, "previous");
const localPackage = `{
  "name" : "Local",
  "services" : [

  ],
  "skills" : [

  ],
  "version" : 3
}
`;

async function git(root: string, args: string[], environment: Record<string, string> = {}): Promise<void> {
  await run(["git", "-C", root, ...args], { capture: true, env: environment });
}

async function initializeRepository(root: string, message: string): Promise<void> {
  await git(root, ["init", "-q", "--initial-branch=main"]);
  await git(root, ["config", "core.ignorecase", "true"]);
  await git(root, ["config", "core.precomposeunicode", "true"]);
  await git(root, ["config", "user.name", "Ox"]);
  await git(root, ["config", "user.email", "local@ox.invalid"]);
  await git(root, ["add", "-A"]);
  await git(root, ["-c", "commit.gpgsign=false", "commit", "-q", "-m", message], {
    GIT_AUTHOR_DATE: "2000-01-01T00:00:00Z",
    GIT_COMMITTER_DATE: "2000-01-01T00:00:00Z",
  });
  const metadata = join(root, ".git");
  await rm(join(metadata, "hooks"), { recursive: true, force: true });
  await rm(join(metadata, "logs"), { recursive: true, force: true });
  await rm(join(metadata, "info", "exclude"), { force: true });
  await rm(join(metadata, "description"), { force: true });
  await rm(join(metadata, "COMMIT_EDITMSG"), { force: true });
  await rm(join(metadata, "index"), { force: true });
  await git(root, ["read-tree", "HEAD"]);
  await git(root, ["-c", "pack.threads=1", "-c", "pack.writeReverseIndex=false", "repack", "-adq"]);
  await git(root, ["prune-packed"]);
  await rm(join(metadata, "objects", "info", "packs"), { force: true });
}

async function addLocalRepositorySeed(root: string): Promise<void> {
  const resources = join(root, "Repositories.bundle");
  await mkdir(resources, { recursive: true });
  const local = join(resources, "Local");
  await mkdir(local, { recursive: true });
  await writeFile(join(local, "repository.json"), localPackage);
  await initializeRepository(local, "Initialize Local repository");
  await rename(join(local, ".git"), join(resources, "Local.git"));
  await rm(local, { recursive: true });
}

try {
  const repository = await refreshBuiltinRepository();
  await writeFile(join(ROOT, "apps/ios/Ox/Resources/ModelServiceActions.json"), `${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n`);
  await writeFile(join(ROOT, "apps/ios/Ox/Resources/ModelGuidance.bundle/evolve/references/model-schemas.md"),
    `# Standard website Action schemas\n\nGenerated from packages/protocol/src/model-actions.ts by bun run build:services. conversation is the shared submit/read/cancel Action; add listModels for model-provider discovery. The existing four model Actions and optional continueModelGeneration remain supported during transition. Copy exact schemas; do not mix protocols on one conversation page.\n\n\`\`\`json\n${JSON.stringify(STANDARD_WEB_ACTION_SCHEMAS, null, 2)}\n\`\`\`\n`);
  await addLocalRepositorySeed(temporary);
  await rm(backup, { recursive: true, force: true });
  const hadPrevious = existsSync(destination);
  if (hadPrevious) await rename(destination, backup);
  try {
    await rename(staging, destination);
    await rm(backup, { recursive: true, force: true });
    await rm(temporary, { recursive: true, force: true });
  } catch (error) {
    if (hadPrevious) await rename(backup, destination);
    throw error;
  }
  console.log(`Validated ${BUILTIN_REPOSITORY_ROOT} services=${repository.services.length} hash=${repository.contentHash?.slice(0, 12)} and built Local repository seed`);
} catch (error) {
  await rm(temporary, { recursive: true, force: true });
  throw error;
}

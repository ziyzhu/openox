import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { ROOT } from "./lib.ts";

const destination = join(ROOT, "ios", "ios", "OxServices.bundle");
const temporary = await mkdtemp(join(dirname(destination), ".ox-services-bundle-"));
const staging = join(temporary, "repository");
const backup = join(dirname(destination), ".ox-services-bundle-previous");
const localPackage = `{
  "name" : "Local",
  "services" : [

  ],
  "version" : 1
}
`;

function repositoryRoot(args: string[]): string {
  const index = args.indexOf("--repository");
  const value = index >= 0 ? args[index + 1] : Bun.env.OX_SERVER_ROOT;
  if (!value) throw new Error("Pass --repository <service-repository> or set OX_SERVER_ROOT");
  const root = resolve(value);
  if (!existsSync(join(root, "src", "export.ts"))) throw new Error(`not a service repository checkout: ${root}`);
  return root;
}

async function exportRepository(root: string, output: string): Promise<void> {
  const process = Bun.spawn(["bun", "run", "export", "--output", output], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  const code = await process.exited;
  if (code !== 0) throw new Error(`OpenOx Services export exited ${code}`);
}

async function git(root: string, args: string[], environment: Record<string, string> = {}): Promise<void> {
  const process = Bun.spawn(["git", "-C", root, ...args], {
    env: { ...Bun.env, ...environment },
    stdout: "pipe",
    stderr: "pipe",
  });
  const code = await process.exited;
  if (code === 0) return;
  const detail = (await new Response(process.stderr).text()).trim();
  throw new Error(`git ${args.join(" ")} failed${detail ? `: ${detail}` : ""}`);
}

async function initializeRepository(root: string, message: string): Promise<void> {
  await git(root, ["init", "-q", "--initial-branch=main"]);
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
}

async function addLocalRepositorySeed(root: string): Promise<void> {
  const resources = join(root, "Repositories.bundle");
  await mkdir(resources, { recursive: true });
  const local = join(resources, "Local");
  await mkdir(local, { recursive: true });
  await writeFile(join(local, "ox.json"), localPackage);
  await initializeRepository(local, "Initialize Local services");
  await rename(join(local, ".git"), join(resources, "Local.git"));
  await rm(local, { recursive: true });
}

try {
  await exportRepository(repositoryRoot(Bun.argv.slice(2)), staging);
  const repository = JSON.parse(await readFile(join(staging, "ox.json"), "utf8")) as {
    services: string[];
    contentHash?: string;
  };
  await addLocalRepositorySeed(staging);
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
  console.log(`Built ${destination} services=${repository.services.length} hash=${repository.contentHash?.slice(0, 12)}`);
} catch (error) {
  await rm(temporary, { recursive: true, force: true });
  throw error;
}

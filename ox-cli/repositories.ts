import { cp, lstat, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { C, dispatch, fail, terminalText, type CliContext, type SubCommand } from "./lib.ts";

type RepositoryPackage = {
  version: 1;
  name: string;
  contentHash?: string;
  services: string[];
};

type RepositoryCheckout = {
  root: string;
  dispose: () => Promise<void>;
};

type Snapshot = {
  root: string;
  gitDir: string;
  head: string;
  repository: RepositoryPackage;
  dispose: () => Promise<void>;
};

const SERVICE_ID = /^(?:web|ios|mcp):[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/;
const CONTENT_HASH = /^[a-f0-9]{64}$/;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

export const SUBS: Record<string, SubCommand> = {
  inspect: { desc: "Inspect a local, localhost, or HTTPS service repository", fn: inspectRepository },
  validate: { desc: "Validate a local, localhost, or HTTPS service repository", fn: validateRepository },
  serve: { desc: "Serve a local or remote service repository on localhost", fn: serveRepository },
};

export async function repository(args: string[], context: CliContext): Promise<void> {
  return dispatch("repository", "Inspect, validate, or locally serve a service repository.", SUBS, args, context);
}

function servicePath(id: string): string {
  const separator = id.indexOf(":");
  return `${id.slice(0, separator)}/${id.slice(separator + 1)}`;
}

function repositoryOrigin(value: string): URL | undefined {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return undefined;
  if (url.username || url.password || url.hash) fail("repository URLs cannot contain credentials or fragments");
  if (url.protocol === "http:" && !LOOPBACK_HOSTS.has(url.hostname)) {
    fail("HTTP repository URLs must use localhost or a loopback address");
  }
  return url;
}

async function git(args: string[], cwd?: string, environment: Record<string, string> = {}): Promise<string> {
  const process = Bun.spawn(["git", ...args], {
    cwd,
    env: { ...Bun.env, ...environment },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [code, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text(),
  ]);
  if (code !== 0) throw new Error(stderr.trim() || `git exited ${code}`);
  return stdout.trim();
}

async function checkout(origin: string): Promise<RepositoryCheckout> {
  const url = repositoryOrigin(origin);
  if (!url) {
    const root = resolve(origin);
    if (!existsSync(root)) fail(`repository does not exist: ${root}`);
    return { root, dispose: async () => {} };
  }
  const temporary = await mkdtemp(join(tmpdir(), "ox-repository-clone-"));
  const root = join(temporary, "checkout");
  try {
    await git(["clone", "--depth", "1", "--single-branch", url.href, root]);
    return { root, dispose: () => rm(temporary, { recursive: true, force: true }) };
  } catch (error) {
    await rm(temporary, { recursive: true, force: true });
    throw error;
  }
}

export function requireRepository(context: CliContext): string {
  return context.repository ?? fail("this command requires --repository <path-or-url>");
}

export async function withRepository<T>(
  origin: string,
  operation: (root: string, repository: RepositoryPackage) => Promise<T>,
): Promise<T> {
  const selected = await checkout(origin);
  try {
    return await operation(selected.root, await readRepository(selected.root));
  } finally {
    await selected.dispose();
  }
}

async function regularFile(path: string, maximumSize: number): Promise<void> {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size > maximumSize) {
    throw new Error(`invalid repository file: ${path}`);
  }
}

async function validateServiceTree(path: string): Promise<void> {
  const root = await lstat(path);
  if (!root.isDirectory() || root.isSymbolicLink()) throw new Error(`invalid service directory: ${path}`);
  let total = 0;
  const pending = [path];
  while (pending.length) {
    const directory = pending.pop()!;
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const child = join(directory, entry.name);
      const metadata = await lstat(child);
      if (metadata.isSymbolicLink()) throw new Error(`symbolic links are unsupported: ${child}`);
      if (metadata.isDirectory()) pending.push(child);
      else if (metadata.isFile()) total += metadata.size;
      else throw new Error(`unsupported repository entry: ${child}`);
      if (total > 4_000_000) throw new Error(`service directory exceeds 4000000 bytes: ${path}`);
    }
  }
}

export async function readRepository(root: string): Promise<RepositoryPackage> {
  const packagePath = join(root, "ox.json");
  await regularFile(packagePath, 512_000);
  const raw = JSON.parse(await readFile(packagePath, "utf8")) as Record<string, unknown>;
  if (Object.keys(raw).some(key => !["version", "name", "contentHash", "services"].includes(key))
    || raw.version !== 1
    || typeof raw.name !== "string"
    || raw.name.trim().length === 0
    || raw.name.length > 100
    || !Array.isArray(raw.services)
    || raw.services.length > 256
    || raw.services.some(service => typeof service !== "string" || !SERVICE_ID.test(service))
    || (raw.contentHash !== undefined && (typeof raw.contentHash !== "string" || !CONTENT_HASH.test(raw.contentHash)))) {
    throw new Error("ox.json is invalid");
  }
  const repository = raw as RepositoryPackage;
  const identities = new Set<string>();
  for (const service of repository.services) {
    const identity = service.slice(service.indexOf(":") + 1);
    if (identities.has(identity)) throw new Error(`duplicate service identity: ${identity}`);
    identities.add(identity);
    const path = join(root, servicePath(service));
    await validateServiceTree(path);
    await regularFile(join(path, "manifest.json"), 512_000);
    if (service.startsWith("web:")) await regularFile(join(path, "actions.js"), 1_000_000);
  }
  return repository;
}

export async function createSnapshot(sourceRoot: string): Promise<Snapshot> {
  const repository = await readRepository(sourceRoot);
  const temporary = await mkdtemp(join(tmpdir(), "ox-repository-snapshot-"));
  const root = join(temporary, "repository");
  await mkdir(root);
  try {
    await writeFile(join(root, "ox.json"), `${JSON.stringify(repository, null, 2)}\n`);
    for (const service of repository.services) {
      const path = servicePath(service);
      await cp(join(sourceRoot, path), join(root, path), { recursive: true, errorOnExist: true });
    }
    await git(["init", "-q", "--initial-branch=main"], root);
    await git(["add", "-A"], root);
    const dates = {
      GIT_AUTHOR_DATE: "2000-01-01T00:00:00Z",
      GIT_COMMITTER_DATE: "2000-01-01T00:00:00Z",
    };
    await git([
      "-c", "user.name=Ox",
      "-c", "user.email=local@ox.invalid",
      "-c", "commit.gpgsign=false",
      "commit", "-q", "-m", "Serve repository snapshot",
    ], root, dates);
    const head = await git(["rev-parse", "HEAD"], root);
    return {
      root,
      gitDir: join(root, ".git"),
      head,
      repository,
      dispose: () => rm(temporary, { recursive: true, force: true }),
    };
  } catch (error) {
    await rm(temporary, { recursive: true, force: true });
    throw error;
  }
}

function packetLine(payload: string): string {
  return (payload.length + 4).toString(16).padStart(4, "0") + payload;
}

async function uploadPack(gitDir: string, req: Request, url: URL): Promise<Response | undefined> {
  const prefix = "/repository.git/";
  if (url.pathname === `${prefix}info/refs` && url.searchParams.get("service") === "git-upload-pack") {
    const process = Bun.spawn(["git", "upload-pack", "--stateless-rpc", "--advertise-refs", gitDir], { stdout: "pipe" });
    const output = await new Response(process.stdout).bytes();
    if (await process.exited !== 0) return new Response("git upload-pack failed", { status: 500 });
    return new Response(new Blob([packetLine("# service=git-upload-pack\n") + "0000", output]), {
      headers: {
        "content-type": "application/x-git-upload-pack-advertisement",
        "cache-control": "no-cache",
      },
    });
  }
  if (url.pathname === `${prefix}git-upload-pack` && req.method === "POST") {
    let input = new Uint8Array(await req.arrayBuffer());
    if (req.headers.get("content-encoding")?.includes("gzip")) input = Bun.gunzipSync(input);
    const process = Bun.spawn(["git", "upload-pack", "--stateless-rpc", gitDir], {
      stdin: input,
      stdout: "pipe",
    });
    const output = await new Response(process.stdout).bytes();
    if (await process.exited !== 0) return new Response("git upload-pack failed", { status: 500 });
    return new Response(output, {
      headers: {
        "content-type": "application/x-git-upload-pack-result",
        "cache-control": "no-cache",
      },
    });
  }
}

function originArgument(args: string[], usage: string): string {
  const values = args.filter(argument => argument !== "--json");
  if (values.includes("-h") || values.includes("--help")) {
    console.log(usage);
    process.exit(0);
  }
  if (values.length !== 1) fail("expected one repository path or URL");
  return values[0]!;
}

async function inspectRepository(args: string[]): Promise<void> {
  const origin = originArgument(args, "Usage: ox repository inspect <path-or-url>");
  const selected = await checkout(origin);
  try {
    process.stdout.write(`${JSON.stringify(await readRepository(selected.root), null, 2)}\n`);
  } finally {
    await selected.dispose();
  }
}

async function validateRepository(args: string[]): Promise<void> {
  const origin = originArgument(args, "Usage: ox repository validate <path-or-url>");
  const selected = await checkout(origin);
  try {
    const manifest = await readRepository(selected.root);
    console.log(`${terminalText("valid", [C.bold, C.sky])} ${manifest.name} services=${manifest.services.length}`);
  } finally {
    await selected.dispose();
  }
}

async function waitForTermination(): Promise<void> {
  await new Promise(resolve => {
    const done = () => {
      process.off("SIGINT", done);
      process.off("SIGTERM", done);
      resolve(undefined);
    };
    process.on("SIGINT", done);
    process.on("SIGTERM", done);
  });
}

async function serveRepository(args: string[]): Promise<void> {
  let origin = "";
  let port = 8100;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--port") port = Number(args[++index]);
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox repository serve <path-or-url> [--port 8100]");
      return;
    } else if (!origin) origin = argument;
    else fail(`unexpected argument: ${argument}`);
  }
  if (!origin) fail("expected a repository path or URL");
  if (!Number.isInteger(port) || port < 0 || port > 65535) fail("--port must be an integer from 0 through 65535");
  const selected = await checkout(origin);
  let snapshot: Snapshot | undefined;
  try {
    snapshot = await createSnapshot(selected.root);
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port,
      routes: { "/health": () => new Response("ok") },
      async fetch(req) {
        const response = await uploadPack(snapshot!.gitDir, req, new URL(req.url));
        return response ?? new Response("not found", { status: 404 });
      },
    });
    const endpoint = `http://127.0.0.1:${server.port}/repository.git`;
    console.log(`READY ${endpoint}`);
    console.log(`repository=${basename(selected.root)} services=${snapshot.repository.services.length} head=${snapshot.head.slice(0, 12)}`);
    await waitForTermination();
    await server.stop(true);
  } finally {
    await snapshot?.dispose();
    await selected.dispose();
  }
}

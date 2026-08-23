import { join, dirname, resolve } from "node:path";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";
import index from "./index.html";

const logInfo = (message: string) => console.info(message);
const logWarn = (message: string) => console.warn(message);

function envPort(name: string, fallback: number): number {
  const value = Number(process.env[name] ?? fallback);
  return Number.isInteger(value) && value > 0 && value <= 65535 ? value : fallback;
}

function envEndpoint(name: string, fallback: string): string {
  const value = process.env[name] ?? fallback;
  try {
    const url = new URL(value);
    return (url.protocol === "ws:" || url.protocol === "wss:") && url.port ? url.toString() : fallback;
  } catch {
    return fallback;
  }
}

const PORT = envPort("PORT", 8001);
const DEBUG_ENDPOINT = envEndpoint("OX_DEBUG_ENDPOINT", "ws://127.0.0.1:9876");
const SIM_DAEMON_PORT = envPort("OX_SIM_DAEMON_PORT", 9909);
const SIM_DAEMON_URL = `http://127.0.0.1:${SIM_DAEMON_PORT}`;
const LOCAL_REPOSITORY = process.env.OX_REPOSITORY ? resolve(process.env.OX_REPOSITORY) : null;
const REMOTE_REPOSITORY = process.env.OX_REPOSITORY_URL ?? null;
const REMOTE_MIRROR = join(homedir(), ".cache", "openox", "repository-remote.git");

function localGitDir(): { ok: true; dir: string } | { ok: false; error: string } {
  if (!LOCAL_REPOSITORY) return { ok: false, error: "set OX_REPOSITORY to a local OpenOx Services checkout" };
  const r = spawnSync("git", ["-C", LOCAL_REPOSITORY, "rev-parse", "--absolute-git-dir"], { encoding: "utf8" });
  if (r.status !== 0) return { ok: false, error: r.stderr.trim() || `${LOCAL_REPOSITORY} is not a Git repository` };
  return { ok: true, dir: r.stdout.trim() };
}

function ensureRemoteMirror(doFetch: boolean): string | null {
  if (!REMOTE_REPOSITORY) return "set OX_REPOSITORY_URL to an HTTPS Git repository";
  if (!existsSync(REMOTE_MIRROR)) {
    mkdirSync(dirname(REMOTE_MIRROR), { recursive: true });
    const r = spawnSync("git", ["clone", "--mirror", "--quiet", REMOTE_REPOSITORY, REMOTE_MIRROR], { encoding: "utf8" });
    if (r.status !== 0) return r.stderr.trim() || `clone exited ${r.status}`;
    return null;
  }
  const configured = spawnSync("git", [`--git-dir=${REMOTE_MIRROR}`, "remote", "set-url", "origin", REMOTE_REPOSITORY], { encoding: "utf8" });
  if (configured.status !== 0) return configured.stderr.trim() || `remote set-url exited ${configured.status}`;
  if (doFetch) {
    const r = spawnSync("git", [`--git-dir=${REMOTE_MIRROR}`, "fetch", "--prune", "--quiet", "origin", "+refs/*:refs/*"], { encoding: "utf8" });
    if (r.status !== 0) {
      logWarn(`remote fetch failed: ${r.stderr.trim()}`);
    }
  }
  return null;
}

function gitDirFor(source: string | null, doFetch: boolean): { ok: true; dir: string } | { ok: false; error: string } {
  if (!source || source === "local") return localGitDir();
  if (source === "remote") {
    const err = ensureRemoteMirror(doFetch);
    if (err) return { ok: false, error: err };
    return { ok: true, dir: REMOTE_MIRROR };
  }
  return { ok: false, error: `unknown source: ${source}` };
}

const FIELD = "\x1f";
const RECORD = "\x1e";

function git(dir: string, args: string[]): { ok: true; stdout: string } | { ok: false; error: string } {
  if (!existsSync(dir)) {
    return { ok: false, error: `OpenOx Services Git directory does not exist: ${dir}` };
  }
  const r = spawnSync("git", [`--git-dir=${dir}`, ...args], { encoding: "utf8" });
  if (r.status !== 0) {
    logWarn(`git ${args.join(" ")} failed: ${r.stderr.trim()}`);
    return { ok: false, error: r.stderr.trim() || `git exited ${r.status}` };
  }
  return { ok: true, stdout: r.stdout };
}

function registryLog(source: string | null, limitRaw: string | null) {
  const dir = gitDirFor(source, true);
  if (!dir.ok) return dir;
  const limit = Math.max(1, Math.min(500, Number(limitRaw) || 200));
  const r = git(dir.dir, [
    "log",
    `--pretty=format:%H${FIELD}%P${FIELD}%an${FIELD}%aI${FIELD}%s${RECORD}`,
    `-n`, String(limit),
  ]);
  if (!r.ok) return r;
  const commits = r.stdout.split(RECORD)
    .map((s) => s.replace(/^\n/, ""))
    .filter(Boolean)
    .map((rec) => {
      const [sha, parents, author, date, subject] = rec.split(FIELD);
      return {
        sha,
        short: sha.slice(0, 10),
        parents: parents ? parents.split(" ") : [],
        author,
        date,
        subject,
      };
    });
  return { ok: true as const, commits };
}

function registryCommit(source: string | null, sha: string) {
  if (!/^[0-9a-f]{4,64}$/i.test(sha)) {
    return { ok: false as const, error: "bad sha" };
  }
  const dir = gitDirFor(source, false);
  if (!dir.ok) return dir;
  const head = git(dir.dir, [
    "log", "-1",
    `--pretty=format:%H${FIELD}%P${FIELD}%an${FIELD}%ae${FIELD}%aI${FIELD}%s${FIELD}%b`,
    sha,
  ]);
  if (!head.ok) return head;
  const [full, parents, author, email, date, subject, ...bodyParts] = head.stdout.split(FIELD);
  const body = bodyParts.join(FIELD).trimEnd();

  const names = git(dir.dir, ["show", "--no-color", "--format=", "--name-status", sha]);
  const files = names.ok
    ? names.stdout.split("\n").filter(Boolean).map((line) => {
        const [status, ...rest] = line.split("\t");
        return { status, path: rest.join("\t") };
      })
    : [];

  const diff = git(dir.dir, ["show", "--no-color", "--format=", "--stat", "--patch", sha]);
  return {
    ok: true as const,
    sha: full,
    short: full.slice(0, 10),
    parents: parents ? parents.split(" ") : [],
    author,
    email,
    date,
    subject,
    body,
    files,
    diff: diff.ok ? diff.stdout : `(${diff.error})`,
  };
}

async function ensureSimDaemon() {
  try {
    const r = await fetch(`${SIM_DAEMON_URL}/health`, { signal: AbortSignal.timeout(500) });
    if (r.ok) return;
  } catch {}
  try {
    const child = Bun.spawn(["sim", "daemon", "--port", String(SIM_DAEMON_PORT)], { stdout: "ignore", stderr: "ignore" });
    child.unref();
    logInfo(`started sim daemon on ${SIM_DAEMON_URL} (pid ${child.pid})`);
  } catch (e) {
    logWarn(`sim daemon unavailable and could not be started: ${(e as Error).message}`);
  }
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
    },
  });
}

if (import.meta.main) {
  void ensureSimDaemon();
  Bun.serve({
    port: PORT,
    development: process.env.NODE_ENV !== "production",
    routes: {
      "/": index,
      "/config": () => json({ debugWSURL: DEBUG_ENDPOINT, simDaemonURL: SIM_DAEMON_URL }),
      "/registry/log": (req) => {
        const url = new URL(req.url);
        const r = registryLog(url.searchParams.get("source"), url.searchParams.get("limit"));
        return json(r, r.ok ? 200 : 500);
      },
      "/registry/commit/:sha": (req) => {
        const url = new URL(req.url);
        const r = registryCommit(url.searchParams.get("source"), req.params.sha);
        return json(r, r.ok ? 200 : 400);
      },
    },
    fetch(req) {
      const url = new URL(req.url);
      logWarn(`unmatched ${req.method} ${url.pathname}`);
      return new Response("not found", { status: 404 });
    },
  });

  logInfo(`ox-dev listening on http://localhost:${PORT} (repository: ${LOCAL_REPOSITORY ?? "unset"})`);
}

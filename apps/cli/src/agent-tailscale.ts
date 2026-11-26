import { spawn } from "node:child_process";
import type { Readable } from "node:stream";
import { AGENT_PROTOCOL_VERSION } from "@openox/protocol/agent";
import { agentLog } from "./agent-log.ts";

type JSONObject = Record<string, unknown>;
export type Tailnet = { name: string; login: string };
export type Admission =
  | { kind: "allowed"; via: "loopback" | "tailnet" }
  | { kind: "rejected"; reason: "unknown_host" | "forwarded_loopback" | "missing_identity" | "not_owner" };
export type Publication = { endpoint: string; exited: Promise<number>; stop: () => Promise<void> };

export const HEALTH_NAME = "ox-agent";
const READY_TIMEOUT_MS = 30_000;
const COMMAND_TIMEOUT_MS = 5000;
const LOOPBACK_HOSTS = ["127.0.0.1", "localhost", "[::1]"];

export function admission(headers: Headers, port: number, tailnet: Tailnet | undefined): Admission {
  const host = headers.get("host")?.toLowerCase() ?? "";
  if (tailnet && host === `${tailnet.name.toLowerCase()}:${port}`) {
    const login = headers.get("tailscale-user-login");
    if (!login) return { kind: "rejected", reason: "missing_identity" };
    return login.toLowerCase() === tailnet.login.toLowerCase() ? { kind: "allowed", via: "tailnet" } : { kind: "rejected", reason: "not_owner" };
  }
  if (!LOOPBACK_HOSTS.some((name) => host === `${name}:${port}`)) return { kind: "rejected", reason: "unknown_host" };
  const forwarded = [...headers.keys()].some((name) => name.startsWith("tailscale-") || name.startsWith("x-forwarded-") || name === "forwarded");
  return forwarded ? { kind: "rejected", reason: "forwarded_loopback" } : { kind: "allowed", via: "loopback" };
}

export function tailscaleBinary(): string {
  return process.env.OX_AGENT_TAILSCALE_BIN ?? "tailscale";
}

export async function tailnetIdentity(binary: string): Promise<Tailnet> {
  const status = await runJSON(binary, ["status", "--json"]);
  if (status.BackendState !== "Running") throw new Error("Tailscale is not running; connect it or pass --local");
  const self = object(status.Self);
  if (self.Online !== true) throw new Error("This machine is offline in Tailscale; connect it or pass --local");
  const name = typeof self.DNSName === "string" ? self.DNSName.replace(/\.$/, "") : "";
  if (!/^[a-z0-9.-]+\.ts\.net$/i.test(name)) throw new Error("Tailscale MagicDNS is unavailable; enable it or pass --local");
  const user = object(object(status.User ?? {})[String(self.UserID)] ?? {});
  const login = typeof user.LoginName === "string" ? user.LoginName : "";
  if (!login) throw new Error("Tailscale did not report the user that owns this machine");
  return { name, login };
}

export function routesPort(status: JSONObject, port: number): boolean {
  return publications(status).some((publication) => {
    const tcp = object(publication.TCP ?? {});
    const web = object(publication.Web ?? {});
    return Object.hasOwn(tcp, String(port)) || Object.keys(web).some((key) => key.endsWith(`:${port}`));
  });
}

function servesTarget(status: JSONObject, name: string, port: number): boolean {
  return publications(status).some((publication) => {
    const site = object(object(publication.Web ?? {})[`${name}:${port}`] ?? {});
    return object(object(site.Handlers ?? {})["/"] ?? {}).Proxy === `http://127.0.0.1:${port}`;
  });
}

function publications(status: JSONObject): JSONObject[] {
  const foreground = status.Foreground;
  const children = foreground && typeof foreground === "object" && !Array.isArray(foreground) ? Object.values(foreground).map(object) : [];
  return [status, ...children];
}

export async function ensurePortFree(binary: string, tailnet: Tailnet, port: number): Promise<void> {
  const status = await runJSON(binary, ["serve", "status", "--json"]);
  if (!routesPort(status, port)) return;
  const orphans = servesTarget(status, tailnet.name, port) && !await listening(port) ? await orphanedServe(port) : [];
  if (!orphans.length) throw new Error(`Tailscale Serve already has a route on HTTPS port ${port}; free it or choose another --port`);
  for (const pid of orphans) signal(pid, "SIGTERM");
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && routesPort(await runJSON(binary, ["serve", "status", "--json"]), port)) await Bun.sleep(250);
  if (routesPort(await runJSON(binary, ["serve", "status", "--json"]), port)) {
    for (const pid of orphans) signal(pid, "SIGKILL");
    await Bun.sleep(500);
  }
  if (routesPort(await runJSON(binary, ["serve", "status", "--json"]), port)) {
    throw new Error(`Tailscale Serve still routes HTTPS port ${port} after stopping a previous ox agent serve`);
  }
  agentLog("tailscale.reclaimed", { port, processes: orphans.length });
}

async function listening(port: number): Promise<boolean> {
  try {
    const socket = await Bun.connect({ hostname: "127.0.0.1", port, socket: { data() {} } });
    socket.end();
    return true;
  } catch {
    return false;
  }
}

async function orphanedServe(port: number): Promise<number[]> {
  const listed = Bun.spawnSync(["/bin/ps", "-axo", "pid=,command="]).stdout.toString();
  const command = `serve --https=${port} --yes http://127.0.0.1:${port}`;
  return listed.split("\n").flatMap((line) => {
    const match = line.trim().match(/^(\d+)\s+(.*)$/);
    return match && /tailscale/.test(match[2]) && match[2].endsWith(command) ? [Number(match[1])] : [];
  });
}

function signal(pid: number, name: NodeJS.Signals) {
  try { process.kill(pid, name); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
}

export async function publish(binary: string, tailnet: Tailnet, port: number): Promise<Publication> {
  const child = start(binary, ["serve", `--https=${port}`, "--yes", `http://127.0.0.1:${port}`]);
  void output(child.stdout);
  const stderr = output(child.stderr);
  let code: number | undefined;
  void child.exited.then((value) => { code = value; }, () => { code = 1; });
  agentLog("tailscale.serve_start", { pid: child.pid, port });
  const stop = async () => {
    if (code === undefined) child.kill("SIGINT");
    const force = setTimeout(() => { if (code === undefined) child.kill("SIGKILL"); }, COMMAND_TIMEOUT_MS);
    try { await child.exited; }
    finally { clearTimeout(force); }
    agentLog("tailscale.serve_stop", { pid: child.pid, code });
  };
  try {
    await waitUntilReachable(binary, tailnet.name, port, () => code);
    return { endpoint: `wss://${tailnet.name}:${port}`, exited: child.exited, stop };
  } catch (error) {
    await stop();
    throw new Error((await stderr).trim() || (error as Error).message);
  }
}

async function waitUntilReachable(binary: string, name: string, port: number, exitCode: () => number | undefined): Promise<void> {
  const deadline = Date.now() + READY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const code = exitCode();
    if (code !== undefined) throw new Error(`Tailscale Serve exited with status ${code}`);
    if (servesTarget(await runJSON(binary, ["serve", "status", "--json"]), name, port)) {
      try {
        const response = await fetch(`https://${name}:${port}/health`, { signal: AbortSignal.timeout(2000) });
        const health = await response.json() as { name?: unknown; protocol?: unknown };
        if (response.ok && health.name === HEALTH_NAME && health.protocol === AGENT_PROTOCOL_VERSION) return;
      } catch {}
    }
    await Bun.sleep(250);
  }
  throw new Error(`Tailscale Serve did not make https://${name}:${port} reachable within ${READY_TIMEOUT_MS / 1000} seconds`);
}

function start(binary: string, args: string[]) {
  const child = spawn(binary, args, { detached: true, stdio: ["ignore", "pipe", "pipe"] });
  const exited = new Promise<number>((resolve, reject) => {
    child.on("error", reject);
    child.on("close", (code) => resolve(code ?? 1));
  });
  const kill = (signal: NodeJS.Signals) => {
    if (!child.pid) return;
    try { process.kill(-child.pid, signal); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error; }
  };
  return { pid: child.pid, stdout: child.stdout, stderr: child.stderr, exited, kill };
}

async function runJSON(binary: string, args: string[]): Promise<JSONObject> {
  const child = start(binary, args);
  const timer = setTimeout(() => child.kill("SIGKILL"), COMMAND_TIMEOUT_MS);
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, output(child.stdout, false), output(child.stderr)]);
    if (code !== 0) throw new Error(stderr.trim() || `tailscale ${args.join(" ")} exited with status ${code}`);
    return object(JSON.parse(stdout));
  } finally {
    clearTimeout(timer);
  }
}

async function output(stream: Readable, bounded = true): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of stream) {
    text += decoder.decode(chunk, { stream: true });
    if (bounded) text = text.slice(-16_384);
  }
  return text + decoder.decode();
}

function object(value: unknown): JSONObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Tailscale returned invalid JSON");
  return value as JSONObject;
}

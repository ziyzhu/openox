import { execFileSync } from "node:child_process";
import { mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { createHttpHandler } from "./serve/server.ts";
import { diagnostic, Sessions } from "./serve/sessions.ts";
import { startTailscaleServe, type ManagedTailscaleServe } from "./serve/tailscale.ts";

const help = `Usage: ox serve [--port <port>] [--directory <path>] [--data-dir <path>] [--pi <executable>]

Serve managed Pi sessions as MCP on loopback, published through Tailscale Serve.
No pairing: restrict access using Tailscale grants/ACLs before starting.

  --port        Loopback HTTP port (default 9877); Tailscale publishes HTTPS on 443
  --directory   Allowed initial working-directory root (default current directory)
  --data-dir    Managed session storage (default ~/.openox/serve)
  --pi          Installed Pi executable (default pi)

Publication requires connected Tailscale, MagicDNS, and HTTPS/Serve enabled.
Ox refuses to replace existing Serve configuration and stops its own foreground
Serve process on exit. TLS and certificate management are handled by Tailscale.

Pi must be installed, authenticated, and project trust configured locally.
Working-directory restrictions are NOT a sandbox. Agents run as your user.
Clients poll read_session; resource subscriptions are not yet provided.
`;

export async function serve(args: string[]): Promise<void> {
  if (args.length === 1 && ["--help", "-h"].includes(args[0]!)) { console.log(help); return; }
  const options: Record<string, string> = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index]!;
    const value = args[index + 1];
    if (!["--port", "--directory", "--data-dir", "--pi"].includes(flag) || !value || value.startsWith("--") || options[flag]) throw new Error(help);
    options[flag] = value;
  }
  const port = Number(options["--port"] ?? 9877);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("Invalid port");
  const root = await realpath(options["--directory"] ?? process.cwd());
  const directory = resolve(options["--data-dir"] ?? join(homedir(), ".openox", "serve"));
  const executable = options["--pi"] ?? "pi";
  try { execFileSync(executable, ["--version"], { timeout: 10_000, stdio: "pipe" }); }
  catch { throw new Error("Pi executable is unavailable; install Pi or specify --pi"); }

  await mkdir(directory, { recursive: true, mode: 0o700 });
  const lock = join(directory, "serve.lock");
  try { await mkdir(lock, { mode: 0o700 }); }
  catch { throw new Error(`Session storage is locked. Check for another ox serve process. After a crash, remove ${lock} only after confirming no server is running.`); }
  const sessions = new Sessions(join(directory, "sessions"), root, executable);
  const controller = new AbortController();
  const shutdown = new Promise<void>((done) => controller.signal.addEventListener("abort", () => done(), { once: true }));
  const stop = () => controller.abort();
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  let publication: ManagedTailscaleServe | undefined;
  let stopServer: (() => void) | undefined;
  try {
    await writeFile(join(lock, "owner.json"), JSON.stringify({ pid: process.pid, address: "127.0.0.1", port }), { mode: 0o600 });
    await sessions.load();
    const allowedHosts = new Set(["127.0.0.1"]);
    const server = Bun.serve({
      hostname: "127.0.0.1", port, idleTimeout: 60, maxRequestBodySize: 1024 * 1024,
      fetch: createHttpHandler(sessions, allowedHosts),
    });
    stopServer = () => { server.stop(true); };
    publication = await startTailscaleServe(port, (name) => allowedHosts.add(name), controller.signal);
    const endpoint = publication.endpoint;
    diagnostic("started", { endpoint, directory: root });
    console.log(`MCP endpoint: ${endpoint}\nAllowed initial directory: ${root}\nAccess: Tailscale grants/ACLs; no pairing.\nPress Ctrl+C to shut down managed Pi processes.`);
    const code = await Promise.race([shutdown.then(() => undefined), publication.exited]);
    if (!controller.signal.aborted && code !== undefined) throw new Error(await publication.exitMessage() || `Tailscale Serve exited with status ${code}`);
  } finally {
    try { await publication?.stop(); }
    finally {
      stopServer?.();
      await sessions.close();
      await rm(lock, { recursive: true, force: true });
      process.off("SIGINT", stop);
      process.off("SIGTERM", stop);
      diagnostic("stopped");
    }
  }
}

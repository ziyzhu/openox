type JSONObject = Record<string, unknown>;

export type ManagedTailscaleServe = {
  endpoint: string;
  exited: Promise<number>;
  stop: () => Promise<void>;
  exitMessage: () => Promise<string>;
};

function object(value: unknown): JSONObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Tailscale returned invalid JSON");
  return value as JSONObject;
}

async function output(stream: ReadableStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  const reader = stream.getReader();
  let text = "";
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) return text + decoder.decode();
      text = (text + decoder.decode(value, { stream: true })).slice(-16_384);
    }
  } finally { reader.releaseLock(); }
}

async function runJSON(binary: string, args: string[]): Promise<JSONObject> {
  const child = Bun.spawn([binary, ...args], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  const timer = setTimeout(() => child.kill(), 5000);
  try {
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), output(child.stderr)]);
    if (code !== 0) throw new Error(stderr.trim() || `Tailscale exited with status ${code}`);
    return object(JSON.parse(stdout));
  } finally { clearTimeout(timer); }
}

function dnsName(status: JSONObject): string {
  if (status.BackendState !== "Running") throw new Error("Tailscale is not running; connect it before starting ox serve");
  const self = object(status.Self);
  if (self.Online !== true) throw new Error("This machine is offline in Tailscale; connect it before starting ox serve");
  const name = typeof self.DNSName === "string" ? self.DNSName.replace(/\.$/, "") : "";
  if (!/^[a-z0-9.-]+\.ts\.net$/i.test(name)) throw new Error("Tailscale MagicDNS is unavailable; enable it before starting ox serve");
  return name;
}

function servesTarget(status: JSONObject, name: string, target: string): boolean {
  const web = object(status.Web ?? {});
  const site = object(web[`${name}:443`] ?? {});
  const handlers = object(site.Handlers ?? {});
  return object(handlers["/"] ?? {}).Proxy === `http://${target}`;
}

/** Foreground Serve only: never reset, replace, or take ownership of an existing route. */
export async function startTailscaleServe(
  port: number,
  allowHost: (name: string) => void,
  signal: AbortSignal,
): Promise<ManagedTailscaleServe> {
  const binary = process.env.OX_TAILSCALE_BIN ?? "tailscale";
  const name = dnsName(await runJSON(binary, ["status", "--json"]));
  const existing = await runJSON(binary, ["serve", "status", "--json"]);
  if (Object.keys(existing).length > 0) throw new Error("Tailscale Serve already has an active route. Ox will not replace it. Explicitly free the existing route before starting ox serve.");
  signal.throwIfAborted();
  allowHost(name);
  const target = `127.0.0.1:${port}`;
  const child = Bun.spawn([binary, "serve", "--yes", target], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
  void output(child.stdout);
  const stderr = output(child.stderr);
  const exited = child.exited;
  let code: number | undefined;
  void exited.then((value) => { code = value; });
  const terminate = () => { if (code === undefined) child.kill("SIGINT"); };
  signal.addEventListener("abort", terminate, { once: true });
  const stop = async () => {
    signal.removeEventListener("abort", terminate);
    terminate();
    const force = setTimeout(() => { if (code === undefined) child.kill("SIGKILL"); }, 5000);
    try { await exited; }
    finally { clearTimeout(force); }
  };
  try {
    const deadline = Date.now() + 30_000;
    let ready = false;
    while (Date.now() < deadline) {
      signal.throwIfAborted();
      if (code !== undefined) throw new Error(`Tailscale Serve exited with status ${code}`);
      const status = await runJSON(binary, ["serve", "status", "--json"]);
      if (servesTarget(status, name, target)) {
        try {
          const response = await fetch(`https://${name}/health`, { signal: AbortSignal.any([signal, AbortSignal.timeout(2000)]) });
          const health = await response.json() as { name?: string; contractVersion?: number };
          if (response.ok && health.name === "ox" && health.contractVersion === 1) { ready = true; break; }
        } catch { signal.throwIfAborted(); }
      }
      await Bun.sleep(250);
    }
    if (!ready) throw new Error("Tailscale Serve did not make the MCP endpoint reachable within 30 seconds");
    return { endpoint: `https://${name}/mcp`, exited, stop, exitMessage: async () => (await stderr).trim() };
  } catch (error) {
    await stop();
    throw new Error((await stderr).trim() || (error as Error).message);
  }
}

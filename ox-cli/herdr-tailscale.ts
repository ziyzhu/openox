type JSONObject = Record<string, unknown>;

export type ManagedTailscaleServe = {
  endpoint: string;
  exited: Promise<number>;
  stop: () => Promise<void>;
  exitMessage: () => Promise<string>;
};

function object(value: unknown, message: string): JSONObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(message);
  return value as JSONObject;
}

function environment(): Record<string, string> {
  return Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));
}

async function run(binary: string, args: string[], timeoutMs = 5_000): Promise<string> {
  const child = Bun.spawn({
    cmd: [binary, ...args],
    env: environment(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => child.kill(), timeoutMs);
  try {
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    const output = stdout.trim();
    if (code !== 0) throw new Error(stderr.trim() || output || `${binary} exited with status ${code}`);
    return output;
  } finally {
    clearTimeout(timer);
  }
}

async function runJSON(binary: string, args: string[]): Promise<JSONObject> {
  const output = await run(binary, args);
  try {
    return object(JSON.parse(output), `${binary} returned invalid JSON`);
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error(`${binary} returned invalid JSON`);
    throw error;
  }
}

export function hasExistingTailscaleServe(status: JSONObject): boolean {
  return Object.keys(status).length > 0;
}

export function tailscaleDNSName(status: JSONObject): string {
  if (status.BackendState !== "Running") throw new Error("Tailscale is not running. Connect Tailscale or use --local-only.");
  const self = object(status.Self, "Tailscale did not report this device. Connect Tailscale or use --local-only.");
  if (self.Online !== true) throw new Error("This Mac is not online in Tailscale. Connect Tailscale or use --local-only.");
  const value = self.DNSName;
  if (typeof value !== "string" || value.length === 0) throw new Error("Tailscale MagicDNS is unavailable. Enable it or use --local-only.");
  return value.replace(/\.$/, "");
}

function servesTarget(status: JSONObject, target: string): boolean {
  return JSON.stringify(status).includes(`http://${target}`);
}

async function waitForServe(
  binary: string,
  target: string,
  healthURL: string,
  exitedCode: () => number | undefined,
): Promise<void> {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const code = exitedCode();
    if (code !== undefined) throw new Error(`Tailscale Serve exited with status ${code}`);
    try {
      const status = await runJSON(binary, ["serve", "status", "--json"]);
      if (servesTarget(status, target)) {
        const response = await fetch(healthURL, { signal: AbortSignal.timeout(2_000) });
        if (response.ok) return;
      }
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("Tailscale Serve exited")) throw error;
    }
    await Bun.sleep(250);
  }
  throw new Error("Tailscale Serve did not make the Herdr bridge reachable within 30 seconds");
}

export async function startTailscaleServe(port: number): Promise<ManagedTailscaleServe> {
  const binary = process.env.OX_TAILSCALE_BIN ?? "tailscale";
  let status: JSONObject;
  try {
    status = await runJSON(binary, ["status", "--json"]);
  } catch (error) {
    throw new Error(`Tailscale is unavailable: ${(error as Error).message}. Install or connect Tailscale, or use --local-only.`);
  }
  const dnsName = tailscaleDNSName(status);
  const existing = await runJSON(binary, ["serve", "status", "--json"]);
  if (hasExistingTailscaleServe(existing)) {
    throw new Error("Tailscale Serve already has an active route. Stop it first or use --local-only; Ox will not replace existing Serve configuration.");
  }
  const target = `127.0.0.1:${port}`;
  const child = Bun.spawn({
    cmd: [binary, "serve", "--yes", target],
    env: environment(),
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  void new Response(child.stdout).text();
  const stderr = new Response(child.stderr).text();
  const exited = child.exited;
  let code: number | undefined;
  void exited.then((value) => { code = value; });
  const healthURL = `https://${dnsName}/health`;
  try {
    await waitForServe(binary, target, healthURL, () => code);
  } catch (error) {
    if (code === undefined) child.kill(2);
    await exited;
    const detail = (await stderr).trim();
    throw new Error(detail || (error as Error).message);
  }
  return {
    endpoint: `https://${dnsName}/mcp`,
    exited,
    stop: async () => {
      if (code === undefined) child.kill(2);
      await exited;
    },
    exitMessage: async () => (await stderr).trim(),
  };
}

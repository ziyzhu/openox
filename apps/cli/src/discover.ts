import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { hostEndpoint } from "./host-connection.ts";
import { HostRPCClient } from "./host-rpc.ts";
import { fail, type CliContext } from "./lib.ts";

type Listener = { port: number; pid?: number; process?: string };
type Device = { name: string; udid: string; state: string; listeners: Listener[] };
type HostCandidate = { endpoint: string; label: string; kind: string; source: string };

export async function discover(args: string[], context: CliContext): Promise<void> {
  let json = false;
  let all = false;
  let timeoutMs = 3000;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--all") all = true;
    else if (argument === "--timeout") timeoutMs = positiveNumber(args[++index], "--timeout");
    else if (argument.startsWith("--timeout=")) timeoutMs = positiveNumber(argument.slice(10), "--timeout");
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox host discover [--all] [--json] [--timeout 3000]");
      return;
    } else fail(`unknown option: ${argument}`);
  }
  const selected = normalizedEndpoint(context.host ?? hostEndpoint());
  const candidates = new Map<string, HostCandidate>();
  candidates.set(selected, { endpoint: selected, label: "configured Host", kind: "unknown", source: "configuration" });
  const daemonPort = validPort(process.env.OX_SIM_DAEMON_PORT, 9909);
  let warning = "";
  try {
    const payload = await discoverSimulators(daemonPort, timeoutMs);
    for (const device of payload.devices ?? []) {
      if (device.state !== "Booted") continue;
      for (const listener of device.listeners ?? []) {
        const endpoint = `ws://127.0.0.1:${listener.port}`;
        candidates.set(endpoint, {
          endpoint,
          label: device.name,
          kind: "ios-simulator",
          source: "sim-daemon",
        });
      }
    }
  } catch (error) {
    warning = `simulator discovery unavailable: ${(error as Error).message}`;
  }
  const tailscale = Bun.which("tailscale");
  if (tailscale) {
    try {
      const { stdout } = await promisify(execFile)(tailscale, ["status", "--json"], { timeout: timeoutMs, maxBuffer: 1024 * 1024 });
      const status = JSON.parse(stdout) as { Peer?: Record<string, { OS?: string; DNSName?: string; TailscaleIPs?: string[]; Online?: boolean }> };
      for (const peer of Object.values(status.Peer ?? {})) {
        if (peer.OS !== "iOS" || (!all && !peer.Online)) continue;
        const address = peer.TailscaleIPs?.find(ip => !ip.includes(":"));
        if (!address) continue;
        const endpoint = `ws://${address}:9876`;
        if (!candidates.has(endpoint)) candidates.set(endpoint, {
          endpoint, label: peer.DNSName?.replace(/\.$/, "") ?? address, kind: "ios-device", source: "tailscale",
        });
      }
    } catch {
      warning = [warning, "Tailscale discovery unavailable; connect Tailscale or pass --host explicitly"].filter(Boolean).join("; ");
    }
  }
  const probed = await Promise.all([...candidates.values()].map(async candidate => {
    const client = new HostRPCClient(candidate.endpoint);
    try {
      const description = await client.describe(timeoutMs);
      return { ...candidate, reachable: true, implementation: description.implementation };
    } catch {
      return { ...candidate, reachable: false };
    } finally { client.close(); }
  }));
  const hosts = probed.filter(host => all || host.reachable);
  if (json) {
    console.log(JSON.stringify({ hosts, ...(warning ? { warning } : {}) }, null, 2));
    return;
  }
  hosts.forEach(host => console.log(`${host.endpoint}  ${host.label} · ${host.kind} · ${host.reachable ? "reachable" : "unavailable"}`));
  if (!hosts.length) console.log("(no reachable Hosts; connect Tailscale and keep Ox open with Host connections enabled)");
  if (warning) process.stderr.write(`${warning}\n`);
}

async function discoverSimulators(port: number, timeoutMs: number): Promise<{ devices?: Device[] }> {
  const endpoint = `http://127.0.0.1:${port}/devices`;
  try {
    return await fetchDevices(endpoint, Math.min(timeoutMs, 500));
  } catch {
    const executable = Bun.which("sim");
    if (!executable) throw new Error("sim is not installed");
    const child = Bun.spawn([executable, "daemon", "--port", String(port)], { stdout: "ignore", stderr: "ignore" });
    child.unref();
  }
  const deadline = Date.now() + timeoutMs;
  let error = "sim daemon did not become ready";
  while (Date.now() < deadline) {
    try {
      return await fetchDevices(endpoint, Math.min(500, Math.max(1, deadline - Date.now())));
    } catch (failure) {
      error = (failure as Error).message;
      await Bun.sleep(100);
    }
  }
  throw new Error(error);
}

async function fetchDevices(endpoint: string, timeoutMs: number): Promise<{ devices?: Device[] }> {
  const response = await fetch(endpoint, { signal: AbortSignal.timeout(timeoutMs) });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.json() as Promise<{ devices?: Device[] }>;
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}

function validPort(value: string | undefined, fallback: number): number {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 && parsed <= 65535 ? parsed : fallback;
}

function normalizedEndpoint(value: string): string {
  try {
    const url = new URL(value);
    return url.pathname === "/" && !url.search && !url.hash ? `${url.protocol}//${url.host}` : url.toString();
  } catch {
    return fail(`invalid Host endpoint: ${value}`);
  }
}

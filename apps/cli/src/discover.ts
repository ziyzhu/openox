import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { hostEndpoint } from "./host-connection.ts";
import { HostRPCClient } from "./host-rpc.ts";
import { fail, type CliContext } from "./lib.ts";

type Device = { name: string; udid: string; state: string; isAvailable?: boolean };
const execute = promisify(execFile);
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
      console.log("Usage: ox host list [--all] [--json] [--timeout 3000]");
      return;
    } else fail(`unknown option: ${argument}`);
  }
  const selected = normalizedEndpoint(context.host ?? hostEndpoint());
  const candidates = new Map<string, HostCandidate>();
  candidates.set(selected, { endpoint: selected, label: "configured Host", kind: "unknown", source: "configuration" });
  let warning = "";
  try {
    for (const candidate of await discoverSimulators(timeoutMs)) {
      candidates.set(candidate.endpoint, candidate);
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

async function discoverSimulators(timeoutMs: number): Promise<HostCandidate[]> {
  if (process.platform !== "darwin") return [];
  const options = { timeout: timeoutMs, maxBuffer: 1024 * 1024 };
  const { stdout } = await execute("xcrun", ["simctl", "list", "devices", "available", "--json"], options);
  const inventory = JSON.parse(stdout) as { devices: Record<string, Device[]> };
  const devices = Object.values(inventory.devices).flat().filter(device => device.state === "Booted" && device.isAvailable !== false);
  return (await Promise.all(devices.map(async device => {
    const { stdout: processes } = await execute("xcrun", ["simctl", "spawn", device.udid, "launchctl", "list"], options);
    const pids = processes.split("\n").filter(line => line.includes("UIKitApplication:"))
      .map(line => line.trim().split(/\s+/)[0]!).filter(pid => /^[1-9][0-9]*$/.test(pid));
    if (!pids.length) return [];
    let sockets: string;
    try {
      sockets = (await execute("lsof", ["-nP", "-a", "-p", pids.join(","), "-iTCP", "-sTCP:LISTEN", "-Fn"], options)).stdout;
    } catch (error) {
      if ((error as { code?: number }).code === 1 && !(error as { stderr?: string }).stderr) return [];
      throw error;
    }
    const ports = new Set([...sockets.matchAll(/^n.*:(\d+)$/gm)].map(match => Number(match[1])));
    return [...ports].map(port => ({ endpoint: `ws://127.0.0.1:${port}`, label: device.name,
      kind: "ios-simulator", source: "simctl" }));
  }))).flat();
}

function positiveNumber(value: string | undefined, flag: string): number {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) fail(`${flag} requires a positive number`);
  return parsed;
}

function normalizedEndpoint(value: string): string {
  try {
    const url = new URL(value);
    return url.pathname === "/" && !url.search && !url.hash ? `${url.protocol}//${url.host}` : url.toString();
  } catch {
    return fail(`invalid Host endpoint: ${value}`);
  }
}

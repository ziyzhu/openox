import { closeSync, mkdirSync, openSync, readFileSync, statSync, unlinkSync, writeSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { run } from "../lib.ts";

// These locks coordinate repository QA runners, not other agents or manual sim use.
export function claimSimulator(device: string): () => void {
  const directory = join(tmpdir(), "ox-qa-tests");
  mkdirSync(directory, { recursive: true });
  const path = join(directory, `${device}.lock`);
  for (;;) {
    try {
      const descriptor = openSync(path, "wx", 0o600);
      writeSync(descriptor, `${process.pid}\n`);
      return () => {
        closeSync(descriptor);
        try { unlinkSync(path); } catch {}
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      if (!staleClaim(path)) throw new Error(`${device} is already claimed by another QA run`);
      try { unlinkSync(path); } catch {}
    }
  }
}

function staleClaim(path: string): boolean {
  try {
    const pid = Number(readFileSync(path, "utf8").trim());
    if (Number.isInteger(pid) && pid > 0) {
      try { process.kill(pid, 0); return false; }
      catch (error) { return (error as NodeJS.ErrnoException).code === "ESRCH"; }
    }
    return Date.now() - statSync(path).mtimeMs > 60_000;
  } catch { return true; }
}

export async function requireSimulator(device: string): Promise<boolean> {
  const { stdout } = await run(["sim", "devices"], { capture: true });
  const inventory = JSON.parse(stdout) as {
    devices?: Record<string, Array<{ name?: string; state?: string; isAvailable?: boolean }>>;
  };
  const simulators = Object.entries(inventory.devices ?? {}).flatMap(([runtime, devices]) =>
    devices.map(candidate => ({ ...candidate, runtime })));
  const target = simulators.find(candidate => candidate.name === device && candidate.isAvailable !== false);
  if (!target) throw new Error(`Simulator ${device} is unavailable; provision the QA pool first`);
  const version = Number(device.slice(-1)) <= 3 ? 26 : 27;
  if (!target.runtime.includes(`.iOS-${version}-`)) throw new Error(`${device} must run iOS ${version}`);
  if (target.state !== "Booted" && target.state !== "Shutdown") throw new Error(`${device} is ${target.state}; wait before running QA`);
  return target.state === "Booted";
}

export async function requireFreePort(port: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const server = createServer();
    server.once("error", () => reject(new Error(`Port ${port} is already in use`)));
    server.listen(port, "127.0.0.1", () => server.close(error => error ? reject(error) : resolve()));
  });
}

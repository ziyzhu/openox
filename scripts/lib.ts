import { spawn, spawnSync } from "bun";
import { resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");

export const ok = (m: string) => console.log(`  ${m}`);
export const info = (m: string) => console.log(`  ${m}`);
export const step = (m: string) => console.log(`${m}`);
export const fail = (m: string): never => {
  console.error(`error: ${m}`);
  process.exit(1);
};

export const header = (title: string, subtitle?: string) => {
  console.log("");
  console.log(subtitle ? `${title} — ${subtitle}` : title);
};

export async function sh(cmd: string[], opts: { cwd?: string; env?: Record<string, string>; check?: boolean } = {}): Promise<number> {
  const p = spawn({
    cmd,
    cwd: opts.cwd ?? ROOT,
    env: { ...process.env, ...(opts.env ?? {}) },
    stdio: ["inherit", "inherit", "inherit"],
  });
  const code = await p.exited;
  if ((opts.check ?? true) && code !== 0) process.exit(code);
  return code;
}

export async function sh$(cmd: string[], opts: { cwd?: string; env?: Record<string, string>; check?: boolean; input?: string } = {}): Promise<string> {
  const p = spawn({
    cmd,
    cwd: opts.cwd ?? ROOT,
    env: { ...process.env, ...(opts.env ?? {}) },
    stdin: opts.input !== undefined ? new Response(opts.input).body! : undefined,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, code] = await Promise.all([new Response(p.stdout).text(), p.exited]);
  if (code !== 0 && opts.check) {
    const err = await new Response(p.stderr).text();
    fail(`Command failed: ${cmd.join(" ")}\n${err}`);
  }
  return stdout;
}

export function need(bin: string): void {
  const r = spawnSync({ cmd: ["which", bin], stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) fail(`${bin} not found on PATH. Install it and retry.`);
}

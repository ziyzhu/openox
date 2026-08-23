import { spawn, spawnSync } from "bun";
import { resolve } from "node:path";
import { type DebugResult } from "../../../scripts/debug-ws.ts";

export const C = {
  bold: "", red: "", green: "",
  cyan: "\x1b[36m",
  dim: "\x1b[2m",
  reset: "\x1b[0m",
};

export const fail = (message: string): never => {
  console.error(`error: ${message}`);
  process.exit(1);
};

export type SubCommand = { fn: (args: string[]) => Promise<void>; desc: string };
export type CommandGroup = {
  fn: (args: string[]) => Promise<void> | void;
  subs: Record<string, { desc: string }>;
};

export const PROG = "debug";

export const ROOT = resolve(import.meta.dir, "../../..");

export const ok = (m: string) => console.log(`  ${m}`);
export const info = (m: string) => console.log(`  ${m}`);
export const step = (m: string) => console.log(`${m}`);
export const header = (title: string, subtitle?: string) => {
  console.log("");
  console.log(subtitle ? `${title} — ${subtitle}` : title);
};

function printUsage(program: string, description: string, groups: Record<string, CommandGroup>): void {
  console.log(`${description}\n`);
  console.log(`Usage: ${program} <command> <subcommand> [...flags] [...args]\n`);
  console.log("Commands:");
  const rows = Object.entries(groups).flatMap(([name, group]) =>
    Object.entries(group.subs).map(([sub, command]) => ({ command: `${name} ${sub}`, description: command.desc }))
  );
  const width = Math.max(...rows.map((row) => row.command.length));
  for (const row of rows) {
    const padding = " ".repeat(width + 4 - row.command.length);
    console.log(`  ${C.cyan}${row.command}${C.reset}${padding}${C.dim}${row.description}${C.reset}`);
  }
  console.log("\nFlags:");
  console.log(`  ${C.cyan}-h, --help${C.reset}     ${C.dim}Display this menu and exit${C.reset}`);
  console.log("");
}

export async function runCli(
  program: string,
  description: string,
  groups: Record<string, CommandGroup>,
  args: string[],
): Promise<void> {
  const [name, ...rest] = args;
  if (!name || name === "help" || name === "-h" || name === "--help") {
    printUsage(program, description, groups);
    return;
  }
  const group = groups[name];
  if (!group) {
    console.error(`Unknown command: ${name}\n`);
    printUsage(program, description, groups);
    process.exitCode = 1;
    return;
  }
  await group.fn(rest);
}

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

export async function dispatch(
  name: string,
  desc: string,
  subs: Record<string, SubCommand>,
  args: string[],
  footer?: () => void,
): Promise<void> {
  const [sub, ...rest] = args;
  if (!sub || sub === "-h" || sub === "--help") {
    console.log(`Usage: ${PROG} ${name} <subcommand> [...flags] [...args]`);
    console.log(`       ${C.dim}${desc}${C.reset}\n`);
    console.log("Subcommands:");
    const width = Math.max(...Object.keys(subs).map((key) => key.length));
    for (const [key, command] of Object.entries(subs)) {
      const padding = " ".repeat(width + 4 - key.length);
      console.log(`  ${C.cyan}${key}${C.reset}${padding}${C.dim}${command.desc}${C.reset}`);
    }
    footer?.();
    console.log("");
    return;
  }
  const command = subs[sub];
  if (!command) fail(`Unknown ${name} subcommand: ${sub}`);
  await command.fn(rest);
}

export function failResult(label: string, error: string): never {
  console.error(`${C.red}${label} failed:${C.reset} ${error}`);
  process.exit(1);
}

export function printResult(result: DebugResult, label: string): void {
  if (result.ok) {
    console.log(JSON.stringify(result.value, null, 2));
  } else {
    failResult(label, result.error);
  }
}

export function takeFlag(args: string[], ...names: string[]): { value: string | undefined; rest: string[] } {
  const rest: string[] = [];
  let value: string | undefined;
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    const assignment = names.map((name) => `${name}=`).find((prefix) => argument.startsWith(prefix));
    if (assignment) {
      value = argument.slice(assignment.length);
      continue;
    }
    if (names.includes(argument)) {
      value = args[++index];
      continue;
    }
    rest.push(argument);
  }
  return { value, rest };
}

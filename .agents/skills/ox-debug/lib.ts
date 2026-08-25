import { resolve } from "node:path";

export const C = {
  red: "",
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

export async function dispatch(
  name: string,
  description: string,
  commands: Record<string, SubCommand>,
  args: string[],
): Promise<void> {
  const [subcommand, ...rest] = args;
  if (!subcommand || subcommand === "-h" || subcommand === "--help") {
    console.log(`Usage: ${PROG} ${name} <subcommand> [...flags] [...args]`);
    console.log(`       ${C.dim}${description}${C.reset}\n`);
    console.log("Subcommands:");
    const width = Math.max(...Object.keys(commands).map(key => key.length));
    for (const [key, command] of Object.entries(commands)) {
      console.log(`  ${C.cyan}${key}${C.reset}${" ".repeat(width + 4 - key.length)}${C.dim}${command.desc}${C.reset}`);
    }
    console.log("");
    return;
  }
  const command = commands[subcommand];
  if (!command) fail(`Unknown ${name} subcommand: ${subcommand}`);
  await command.fn(rest);
}

export function failResult(label: string, error: string): never {
  console.error(`${C.red}${label} failed:${C.reset} ${error}`);
  process.exit(1);
}

function printUsage(program: string, description: string, groups: Record<string, CommandGroup>): void {
  console.log(`${description}\n`);
  console.log(`Usage: ${program} <command> <subcommand> [...flags] [...args]\n`);
  console.log("Commands:");
  const rows = Object.entries(groups).flatMap(([name, group]) =>
    Object.entries(group.subs).map(([subcommand, command]) => ({
      command: `${name} ${subcommand}`,
      description: command.desc,
    }))
  );
  const width = Math.max(...rows.map(row => row.command.length));
  for (const row of rows) {
    console.log(`  ${C.cyan}${row.command}${C.reset}${" ".repeat(width + 4 - row.command.length)}${C.dim}${row.description}${C.reset}`);
  }
  console.log(`\nFlags:\n  ${C.cyan}-h, --help${C.reset}     ${C.dim}Display this menu and exit${C.reset}\n`);
}

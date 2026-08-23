import { type DebugResult } from "./debug-ws.ts";
import { type RuntimeName } from "./service-runtime.ts";

export const C = {
  bold: "\x1b[1m",
  harvest: "\x1b[38;2;242;148;26m",
  sky: "\x1b[38;2;126;157;156m",
  moon: "\x1b[38;2;196;211;214m",
  paleBlue: "\x1b[38;2;147;176;188m",
  dim: "\x1b[2m",
  reset: "\x1b[0m",
};

export const CLI_LOGO = "■ □ □ ■\n■ ■ ■ ■  Ox CLI\n□ ■ ■ □\n□ ■ ■ □";

type TerminalStream = { isTTY?: boolean };
type Environment = Record<string, string | undefined>;

export function terminalText(
  text: string,
  styles: string[],
  stream: TerminalStream = process.stdout,
  environment: Environment = process.env,
): string {
  if (!stream.isTTY || environment.NO_COLOR !== undefined || environment.TERM === "dumb") return text;
  return `${C.reset}${styles.join("")}${text}${C.reset}`;
}

export function chromeDiagnostic(message: string): void {
  process.stderr.write(`${terminalText(`[ox:chrome] ${message}`, [C.moon, C.dim], process.stderr)}\n`);
}

export function chromeAttention(message: string): void {
  process.stderr.write(`${terminalText(`[ox:chrome] ${message}`, [C.bold, C.paleBlue], process.stderr)}\n`);
}

function writeError(message: string): void {
  process.stderr.write(`${terminalText(message, [C.bold, C.moon], process.stderr)}\n`);
}

export const fail = (message: string): never => {
  writeError(`error: ${message}`);
  process.exit(1);
};

export type CliContext = { runtime: RuntimeName; root?: string; session?: string; repository?: string };
export type SubCommand = { fn: (args: string[], context: CliContext) => Promise<void>; desc: string };
export type CommandGroup = {
  fn: (args: string[], context: CliContext) => Promise<void> | void;
  desc: string;
  subs?: Record<string, { desc: string }>;
};

function printUsage(program: string, description: string, groups: Record<string, CommandGroup>): void {
  console.log(terminalText(CLI_LOGO, [C.bold, C.harvest]));
  console.log(`${description}\n`);
  console.log(`Usage: ${program} [--root <path>] [--repository <path-or-url>] [--runtime <ios|chrome>] [--session <id>] <command> [...flags] [...args]\n`);
  console.log("Commands:");
  const rows = Object.entries(groups).flatMap(([name, group]) => {
    const subs = Object.entries(group.subs ?? {});
    return subs.length
      ? subs.map(([sub, command]) => ({ command: `${name} ${sub}`, description: command.desc }))
      : [{ command: name, description: group.desc }];
  });
  const width = Math.max(...rows.map((row) => row.command.length));
  for (const row of rows) {
    const padding = " ".repeat(width + 4 - row.command.length);
    console.log(`  ${terminalText(row.command, [C.sky])}${padding}${terminalText(row.description, [C.dim])}`);
  }
  console.log("\nFlags:");
  console.log(`  ${terminalText("--root <path>", [C.sky])}           ${terminalText("Profile containing profile.json", [C.dim])}`);
  console.log(`  ${terminalText("--repository <origin>", [C.sky])}  ${terminalText("Service repository path or Git URL", [C.dim])}`);
  console.log(`  ${terminalText("--runtime <ios|chrome>", [C.sky])}  ${terminalText("Service execution runtime (default: ios)", [C.dim])}`);
  console.log(`  ${terminalText("--session <id>", [C.sky])}          ${terminalText("Target runtime service/tab or named Herdr session", [C.dim])}`);
  console.log(`  ${terminalText("-h, --help", [C.sky])}             ${terminalText("Display this menu and exit", [C.dim])}`);
  console.log("");
}

export function parseGlobalOptions(args: string[]): { context: CliContext; rest: string[] } {
  let runtime: RuntimeName = "ios";
  let runtimeSeen = false;
  let root: string | undefined;
  let rootSeen = false;
  let session: string | undefined;
  let sessionSeen = false;
  let repository: string | undefined = process.env.OX_REPOSITORY;
  let repositorySeen = false;
  const rest: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    let value: string | undefined;
    if (argument === "--root") {
      value = args[++index];
      if (rootSeen) throw new Error("--root may only be specified once");
      rootSeen = true;
      if (!value) throw new Error("--root requires a path");
      root = value;
      continue;
    } else if (argument === "--repository") {
      value = args[++index];
      if (repositorySeen) throw new Error("--repository may only be specified once");
      repositorySeen = true;
      if (!value) throw new Error("--repository requires a path or URL");
      repository = value;
      continue;
    } else if (argument.startsWith("--repository=")) {
      value = argument.slice("--repository=".length);
      if (repositorySeen) throw new Error("--repository may only be specified once");
      repositorySeen = true;
      if (!value) throw new Error("--repository requires a path or URL");
      repository = value;
      continue;
    } else if (argument.startsWith("--root=")) {
      value = argument.slice("--root=".length);
      if (rootSeen) throw new Error("--root may only be specified once");
      rootSeen = true;
      if (!value) throw new Error("--root requires a path");
      root = value;
      continue;
    } else if (argument === "--session") {
      value = args[++index];
      if (sessionSeen) throw new Error("--session may only be specified once");
      sessionSeen = true;
      if (!value) throw new Error("--session requires an id");
      session = value;
      continue;
    } else if (argument.startsWith("--session=")) {
      value = argument.slice("--session=".length);
      if (sessionSeen) throw new Error("--session may only be specified once");
      sessionSeen = true;
      if (!value) throw new Error("--session requires an id");
      session = value;
      continue;
    } else if (argument === "--runtime") {
      value = args[++index];
    } else if (argument.startsWith("--runtime=")) {
      value = argument.slice("--runtime=".length);
    } else {
      rest.push(argument);
      continue;
    }
    if (runtimeSeen) throw new Error("--runtime may only be specified once");
    runtimeSeen = true;
    if (!value) throw new Error("--runtime requires ios or chrome");
    if (value !== "ios" && value !== "chrome") throw new Error(`unsupported runtime: ${value}`);
    runtime = value;
  }
  return { context: { runtime, ...(root ? { root } : {}), ...(session ? { session } : {}), ...(repository ? { repository } : {}) }, rest };
}

export async function runCli(
  program: string,
  description: string,
  groups: Record<string, CommandGroup>,
  args: string[],
): Promise<void> {
  let parsed: ReturnType<typeof parseGlobalOptions>;
  try {
    parsed = parseGlobalOptions(args);
  } catch (error) {
    writeError(`error: ${(error as Error).message}`);
    process.exitCode = 1;
    return;
  }
  const [name, ...rest] = parsed.rest;
  if (!name || name === "help" || name === "-h" || name === "--help") {
    printUsage(program, description, groups);
    return;
  }
  const group = groups[name];
  if (!group) {
    writeError(`Unknown command: ${name}`);
    console.log("");
    printUsage(program, description, groups);
    process.exitCode = 1;
    return;
  }
  await group.fn(rest, parsed.context);
}

export async function dispatch(
  name: string,
  desc: string,
  subs: Record<string, SubCommand>,
  args: string[],
  context: CliContext,
  footer?: () => void,
): Promise<void> {
  const [sub, ...rest] = args;
  if (!sub || sub === "-h" || sub === "--help") {
    console.log(`Usage: ox ${name} <subcommand> [...flags] [...args]`);
    console.log(`       ${terminalText(desc, [C.dim])}\n`);
    console.log("Subcommands:");
    const width = Math.max(...Object.keys(subs).map((key) => key.length));
    for (const [key, command] of Object.entries(subs)) {
      const padding = " ".repeat(width + 4 - key.length);
      console.log(`  ${terminalText(key, [C.sky])}${padding}${terminalText(command.desc, [C.dim])}`);
    }
    footer?.();
    console.log("");
    return;
  }
  const command = subs[sub];
  if (!command) fail(`Unknown ${name} subcommand: ${sub}`);
  await command.fn(rest, context);
}

export function failResult(label: string, error: string): never {
  writeError(`${label} failed: ${error}`);
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

import { type DebugResult } from "./debug-ws.ts";

export const C = {
  bold: "\x1b[1m",
  harvest: "\x1b[38;2;242;148;26m",
  sky: "\x1b[38;2;126;157;156m",
  moon: "\x1b[38;2;196;211;214m",
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

function writeError(message: string): void {
  process.stderr.write(`${terminalText(message, [C.bold, C.moon], process.stderr)}\n`);
}

export const fail = (message: string): never => {
  writeError(`error: ${message}`);
  process.exit(1);
};

export type CliContext = { host?: string; profile?: string; chat?: string; repository?: string };
export type SubCommand = { fn: (args: string[], context: CliContext) => Promise<void>; desc: string };
export type CommandGroup = {
  fn: (args: string[], context: CliContext) => Promise<void> | void;
  desc: string;
  subs?: Record<string, { desc: string }>;
};

function printUsage(program: string, description: string, groups: Record<string, CommandGroup>): void {
  console.log(terminalText(CLI_LOGO, [C.bold, C.harvest]));
  console.log(`${description}\n`);
  console.log(`Usage: ${program} [--host <ws-url>] [--chat <chat-id>] [--profile <path>] [--repository <path-or-url>] <command> [...flags] [...args]\n`);
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
  const flags = [
    ["--host <ws-url>", "Ox Host WebSocket endpoint"],
    ["--chat <chat-id>", "Chat-bound VM on the Host"],
    ["--profile <path>", "Profile directory for direct administration"],
    ["--repository <origin>", "Service repository path or Git URL"],
    ["-v, --version", "Display the installed version and exit"],
    ["-h, --help", "Display this menu and exit"],
  ];
  const flagWidth = Math.max(...flags.map(([flag]) => flag!.length));
  for (const [flag, detail] of flags) {
    console.log(`  ${terminalText(flag!, [C.sky])}${" ".repeat(flagWidth + 4 - flag!.length)}${terminalText(detail!, [C.dim])}`);
  }
  console.log("");
}

export function parseGlobalOptions(args: string[]): { context: CliContext; rest: string[] } {
  let host: string | undefined;
  let hostSeen = false;
  let profile: string | undefined;
  let profileSeen = false;
  let chat: string | undefined;
  let chatSeen = false;
  let repository: string | undefined = process.env.OX_REPOSITORY;
  let repositorySeen = false;
  const rest: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    let value: string | undefined;
    if (argument === "--host") {
      value = args[++index];
      if (hostSeen) throw new Error("--host may only be specified once");
      hostSeen = true;
      if (!value) throw new Error("--host requires a WebSocket URL");
      host = value;
      continue;
    } else if (argument.startsWith("--host=")) {
      value = argument.slice("--host=".length);
      if (hostSeen) throw new Error("--host may only be specified once");
      hostSeen = true;
      if (!value) throw new Error("--host requires a WebSocket URL");
      host = value;
      continue;
    } else if (argument === "--profile") {
      value = args[++index];
      if (profileSeen) throw new Error("--profile may only be specified once");
      profileSeen = true;
      if (!value) throw new Error("--profile requires a path");
      profile = value;
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
    } else if (argument.startsWith("--profile=")) {
      value = argument.slice("--profile=".length);
      if (profileSeen) throw new Error("--profile may only be specified once");
      profileSeen = true;
      if (!value) throw new Error("--profile requires a path");
      profile = value;
      continue;
    } else if (argument === "--chat") {
      value = args[++index];
      if (chatSeen) throw new Error("--chat may only be specified once");
      chatSeen = true;
      if (!value) throw new Error("--chat requires a chat id");
      chat = value;
      continue;
    } else if (argument.startsWith("--chat=")) {
      value = argument.slice("--chat=".length);
      if (chatSeen) throw new Error("--chat may only be specified once");
      chatSeen = true;
      if (!value) throw new Error("--chat requires a chat id");
      chat = value;
      continue;
    } else if (argument === "--runtime" || argument.startsWith("--runtime=")) {
      throw new Error("--runtime was removed; the selected Host owns service page implementation");
    } else if (argument === "--session" || argument.startsWith("--session=")) {
      throw new Error("--session was removed; use --chat for ox vm or --herdr-session for ox herdr");
    } else if (argument === "--vm-session" || argument.startsWith("--vm-session=")) {
      throw new Error("--vm-session was renamed to --chat");
    } else if (argument === "--root" || argument.startsWith("--root=")) {
      throw new Error("--root was renamed to --profile");
    } else {
      rest.push(argument);
      continue;
    }
  }
  return { context: { ...(host ? { host } : {}), ...(profile ? { profile } : {}), ...(chat ? { chat } : {}), ...(repository ? { repository } : {}) }, rest };
}

export async function runCli(
  program: string,
  version: string,
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
  if (parsed.rest.length === 1 && (parsed.rest[0] === "-v" || parsed.rest[0] === "--version")) {
    console.log(version);
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
  try {
    validateContext(name, rest[0], parsed.context);
  } catch (error) {
    writeError(`error: ${(error as Error).message}`);
    process.exitCode = 1;
    return;
  }
  await group.fn(rest, parsed.context);
}

function validateContext(command: string, subcommand: string | undefined, context: CliContext): void {
  const profileCommands = new Set(["memory", "soul", "skills", "artifacts", "chats", "skill"]);
  const liveServiceCommands = new Set(["status", "invoke", "eval", "reload", "sync", "test"]);
  const repositoryServiceCommands = new Set(["list", "inspect", "actions", "skills"]);
  if (context.chat && command !== "vm") throw new Error("--chat applies only to ox vm");
  if (context.profile && !profileCommands.has(command)) throw new Error("--profile applies only to direct Profile administration commands");
  if (context.host && command !== "vm" && !(command === "service" && (!subcommand || liveServiceCommands.has(subcommand)))) {
    throw new Error("--host applies only to ox vm and live ox service commands");
  }
  if (context.repository && command !== "repository" && !(command === "service" && (!subcommand || repositoryServiceCommands.has(subcommand)))) {
    throw new Error("--repository applies only to ox repository and offline ox service commands");
  }
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

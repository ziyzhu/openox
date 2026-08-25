import { readFile } from "node:fs/promises";
import { Value } from "@sinclair/typebox/value";
import {
  VMControlRequestSchema,
  VMControlResponseSchema,
  VM_PROTOCOL_VERSION,
} from "../../../protocol/host/schema.ts";
import { runOnce, type DebugResult } from "./debug-ws.ts";
import { dispatch, fail, failResult, terminalText, C, type CliContext, type SubCommand } from "./lib.ts";

const protocolVersion = VM_PROTOCOL_VERSION;

type VMResult = DebugResult & {
  protocolVersion?: number;
  value?: unknown;
  logs?: Array<{ level?: string; message?: string }>;
};

export const SUBS: Record<string, SubCommand> = {
  inspect: { desc: "Inspect the selected Host, chat-bound VM, and VFS roots (--json)", fn: inspect },
  functions: { desc: "List the ox.* functions exposed by the VM (--json)", fn: functions },
  help: { desc: "Print the complete contract for one ox.* function", fn: help },
  call: { desc: "Call one ox.* function with structured JSON arguments", fn: call },
  eval: { desc: "Run arbitrary JavaScript in the selected chat-bound VM", fn: evaluate },
  skills: { desc: "List the skills visible to the selected chat-bound VM", fn: skills },
  skill: { desc: "Read one skill through the selected chat-bound VM", fn: skill },
};

export async function vm(args: string[], context: CliContext): Promise<void> {
  return dispatch("vm", "Connect to an Ox Host and use its agent VM contract.", SUBS, args, context);
}

async function inspect(args: string[], context: CliContext): Promise<void> {
  const options = parseOutputOptions(args, 30000);
  const result = await request("vm-inspect", context, options.timeoutMs);
  if (options.json) {
    printVMJSON(result);
    return;
  }
  const value = valueObject(result);
  const host = object(value.host);
  const runtime = object(value.vm);
  const chat = value.session === null ? undefined : object(value.session);
  console.log(`${terminalText("Host", [C.sky])}       ${host.kind ?? "unknown"} ${host.mode ?? ""} via ${host.transport ?? "unknown"}`.trimEnd());
  console.log(`${terminalText("VM", [C.sky])}         ${runtime.contract ?? "unknown"} on ${runtime.engine ?? "unknown"}`);
  console.log(`${terminalText("Lifetime", [C.sky])}   ${runtime.lifetime ?? "unknown"}; ${runtime.sessionBinding ?? "unknown"}-bound execution`);
  console.log(`${terminalText("Chat", [C.sky])}       ${chat?.id ?? "none"}${chat?.temporary === true ? " (temporary)" : ""}`);
  console.log(`${terminalText("Functions", [C.sky])}  ${runtime.functionCount ?? 0}`);
  console.log(`${terminalText("VFS", [C.sky])}        ${Array.isArray(value.vfsRoots) ? value.vfsRoots.join(", ") : "unavailable"}`);
}

async function functions(args: string[], context: CliContext): Promise<void> {
  const options = parseOutputOptions(args, 30000);
  const result = await request("vm-functions", context, options.timeoutMs);
  const catalog = object(valueObject(result).functions);
  if (options.json) {
    console.log(JSON.stringify(catalog, null, 2));
    return;
  }
  for (const name of Object.keys(catalog).sort()) {
    const schema = object(catalog[name]);
    const description = typeof schema.description === "string" ? oneLine(schema.description) : "";
    console.log(`${terminalText(name, [C.sky])}${description ? `  ${terminalText(description, [C.dim])}` : ""}`);
  }
}

async function help(args: string[], context: CliContext): Promise<void> {
  const options = parsePositionals(args, 30000);
  const name = options.positionals[0];
  if (!name || options.positionals.length !== 1) fail("Usage: ox vm help <ox.function> [--json] [--timeout 30000]");
  const result = await request("vm-functions", context, options.timeoutMs, { function: name });
  const value = valueObject(result);
  if (options.json) {
    console.log(JSON.stringify(value, null, 2));
    return;
  }
  if (typeof value.help !== "string") fail("VM Host returned invalid function help");
  console.log(value.help);
}

async function call(args: string[], context: CliContext): Promise<void> {
  let argumentsText: string | undefined;
  let argumentsFile: string | undefined;
  let timeoutMs = 60000;
  let json = false;
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--args") argumentsText = requiredValue(args, ++index, "--args");
    else if (argument.startsWith("--args=")) argumentsText = argument.slice("--args=".length);
    else if (argument === "--args-file") argumentsFile = requiredValue(args, ++index, "--args-file");
    else if (argument.startsWith("--args-file=")) argumentsFile = argument.slice("--args-file=".length);
    else if (argument === "--timeout") timeoutMs = timeoutValue(requiredValue(args, ++index, "--timeout"), 60000);
    else if (argument.startsWith("--timeout=")) timeoutMs = timeoutValue(argument.slice("--timeout=".length), 60000);
    else if (argument === "--json") json = true;
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox vm call <ox.function> [--args '{}'] [--args-file <path|->] [--json] [--timeout 60000]");
      return;
    } else if (argument.startsWith("-")) fail(`unknown option: ${argument}`);
    else positionals.push(argument);
  }
  if (positionals.length !== 1) fail("ox vm call requires exactly one ox.* function name");
  if (argumentsText !== undefined && argumentsFile !== undefined) fail("use either --args or --args-file, not both");
  const raw = argumentsFile !== undefined ? await inputText(argumentsFile) : argumentsText ?? "{}";
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    fail(`invalid VM arguments JSON: ${(error as Error).message}`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) fail("VM function arguments must be a JSON object");
  const result = await request("vm-call", context, timeoutMs, { function: positionals[0], arguments: parsed });
  printExecution(result, json);
}

async function evaluate(args: string[], context: CliContext): Promise<void> {
  let script: string | undefined;
  let scriptFile: string | undefined;
  let timeoutMs = 60000;
  let json = false;
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--script") script = requiredValue(args, ++index, "--script");
    else if (argument.startsWith("--script=")) script = argument.slice("--script=".length);
    else if (argument === "--script-file") scriptFile = requiredValue(args, ++index, "--script-file");
    else if (argument.startsWith("--script-file=")) scriptFile = argument.slice("--script-file=".length);
    else if (argument === "--timeout") timeoutMs = timeoutValue(requiredValue(args, ++index, "--timeout"), 60000);
    else if (argument.startsWith("--timeout=")) timeoutMs = timeoutValue(argument.slice("--timeout=".length), 60000);
    else if (argument === "--json") json = true;
    else if (argument === "-h" || argument === "--help") {
      console.log("Usage: ox vm eval (--script '<javascript>' | --script-file <path|->) [--json] [--timeout 60000]");
      return;
    } else if (argument.startsWith("-")) fail(`unknown option: ${argument}`);
    else positionals.push(argument);
  }
  if (script !== undefined && scriptFile !== undefined) fail("use either --script or --script-file, not both");
  if (positionals.length > 1 || (positionals.length && (script !== undefined || scriptFile !== undefined))) {
    fail("provide one VM script");
  }
  const source = scriptFile !== undefined ? await inputText(scriptFile) : script ?? positionals[0];
  if (!source) fail("ox vm eval requires a script");
  const result = await request("vm-eval", context, timeoutMs, { script: source });
  printExecution(result, json);
}

async function skills(args: string[], context: CliContext): Promise<void> {
  const options = parseOutputOptions(args, 60000);
  const result = await request("vm-call", context, options.timeoutMs, {
    function: "ox.fs.list",
    arguments: { path: "skills", purpose: "List VM skills" },
  });
  const value = valueObject(result);
  if (options.json) {
    printVMJSON(result);
    return;
  }
  const items = Array.isArray(value.items) ? value.items : [];
  for (const item of items) console.log(String(object(item).path ?? ""));
  if (value.truncated === true) console.log(terminalText("Results truncated", [C.dim]));
}

async function skill(args: string[], context: CliContext): Promise<void> {
  const [subcommand, name, ...rest] = args;
  if (subcommand === "-h" || subcommand === "--help" || !subcommand) {
    console.log("Usage: ox vm skill read <name> [--json] [--timeout 60000]");
    return;
  }
  if (subcommand !== "read" || !name) fail("Usage: ox vm skill read <name> [--json] [--timeout 60000]");
  const options = parseOutputOptions(rest, 60000);
  const result = await request("vm-call", context, options.timeoutMs, {
    function: "ox.fs.read",
    arguments: { path: `skills/${name}/SKILL.md`, purpose: "Read VM skill" },
  });
  const value = valueObject(result);
  if (options.json) {
    printVMJSON(result);
    return;
  }
  if (typeof value.text !== "string") fail("VM skill is not readable text");
  process.stdout.write(value.text.endsWith("\n") ? value.text : `${value.text}\n`);
}

async function request(
  kind: string,
  context: CliContext,
  timeoutMs: number,
  fields: Record<string, unknown> = {},
): Promise<VMResult> {
  const envelope = {
    kind,
    id: crypto.randomUUID(),
    protocolVersion,
    ...(context.chat && kind !== "vm-functions" ? { sessionId: context.chat } : {}),
    ...fields,
  };
  if (!Value.Check(VMControlRequestSchema, envelope)) fail(`invalid ${kind} request`);
  const result = await runOnce(envelope, timeoutMs, context.host) as VMResult;
  if (result.protocolVersion !== undefined && !Value.Check(VMControlResponseSchema, result)) {
    fail(`Host returned an invalid ${kind} response`);
  }
  if (!result.ok) failResult(kind, result.error);
  if (!Value.Check(VMControlResponseSchema, result)) fail(`Host omitted the ${kind} protocol envelope`);
  return result;
}

function printExecution(result: VMResult, json: boolean): void {
  if (json) {
    printVMJSON(result);
    return;
  }
  for (const log of result.logs ?? []) {
    const level = log.level && log.level !== "log" ? `[${log.level}] ` : "";
    process.stderr.write(`${level}${log.message ?? ""}\n`);
  }
  console.log(JSON.stringify(result.value ?? null, null, 2));
}

function printVMJSON(result: VMResult): void {
  console.log(JSON.stringify({
    protocolVersion: result.protocolVersion,
    value: result.value ?? null,
    ...(result.logs ? { logs: result.logs } : {}),
  }, null, 2));
}

function parseOutputOptions(args: string[], defaultTimeout: number): { json: boolean; timeoutMs: number } {
  const parsed = parsePositionals(args, defaultTimeout);
  if (parsed.positionals.length) fail(`unexpected argument: ${parsed.positionals[0]}`);
  return parsed;
}

function parsePositionals(args: string[], defaultTimeout: number): { json: boolean; timeoutMs: number; positionals: string[] } {
  let json = false;
  let timeoutMs = defaultTimeout;
  const positionals: string[] = [];
  for (let index = 0; index < args.length; index++) {
    const argument = args[index]!;
    if (argument === "--json") json = true;
    else if (argument === "--timeout") timeoutMs = timeoutValue(requiredValue(args, ++index, "--timeout"), defaultTimeout);
    else if (argument.startsWith("--timeout=")) timeoutMs = timeoutValue(argument.slice("--timeout=".length), defaultTimeout);
    else if (argument === "-h" || argument === "--help") positionals.push(argument);
    else if (argument.startsWith("-")) fail(`unknown option: ${argument}`);
    else positionals.push(argument);
  }
  return { json, timeoutMs, positionals };
}

function timeoutValue(value: string, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function requiredValue(args: string[], index: number, flag: string): string {
  const value = args[index];
  if (!value) fail(`${flag} requires a value`);
  return value;
}

async function inputText(path: string): Promise<string> {
  return path === "-" ? Bun.stdin.text() : readFile(path, "utf8");
}

function valueObject(result: VMResult): Record<string, any> {
  return object(result.value);
}

function object(value: unknown): Record<string, any> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : {};
}

function oneLine(value: string): string {
  return value.split(/\s+/u).join(" ");
}
